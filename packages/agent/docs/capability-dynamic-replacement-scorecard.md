# Capability Dynamic Replacement Scorecard

Status: **foundational runtime route complete**

Current foundation score: **94/100**

This scorecard tracks the path from measurable modularity to governed dynamic
replacement. It is intentionally narrower than "self-update everything": the
first route target is the read-only `git_status` operation, and the route is
scoped, explicit, versioned, auditable, disableable, and rollbackable. The
minimal engine remains responsible for registry truth, grants, resource
custody, redaction, trace/audit, module governance, route decisions, and
fail-closed routing.

The current implementation can record candidates, route bindings, route
activations, route events, and route rollbacks. The dispatcher can resolve an
active scoped `git_status` route, require accepted shadow evidence, verify the
candidate lifecycle/runtime refs, and route to a supervised module-runtime provider-safe adapter projection. If the runtime envelope, lifecycle
authorization, version refs, scope, network policy, or projection shape are not
safe, routing fails closed and does not fall back to a built-in success result.
Successful routed invocations report route state
`active_route_module_adapter_projection`; rejected projections report
`active_route_failed_closed`.

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
| Runtime route model | 15 | passed | 15 | Active replacement routes are explicit, versioned, scoped, reversible, and executed through the supervised module-runtime provider-safe projection boundary for `git_status`. |
| Candidate module contract | 15 | partial | 13 | Candidates publish schemas, authority, risk, evidence, lifecycle/runtime refs, rollback controls, and provider-safe projection contracts. The first route proves a metadata-supervised read-only adapter projection, not arbitrary module code execution. |
| Shadow execution | 12 | passed | 12 | Built-in and candidate can run side by side safely before activation. Current shadow trial is metadata-only for `git_status` and preserves no-candidate-execution proof. |
| Activation and routing | 14 | passed | 14 | Only approved adapter-replaceable/module-owned operations can route to candidates. Current activation is limited to `git_status`, requires approval refs, candidate/binding/shadow-evidence stale guards, and routes through the supervised runtime projection boundary. |
| Rollback and disable | 12 | passed | 12 | Every route can be disabled, rolled back, and audited deterministically. Current route events and rollback resources provide terminal route controls. |
| Agent workflow | 10 | partial | 8 | Tron can inspect gaps, propose replacements, run trials, request approval, activate, invoke, explain, disable, and roll back the first route through durable operations. Broader live stress workflows should now test breadth rather than unblock foundation. |
| Cockpit/session visibility | 10 | partial | 9 | Engine Cockpit can derive route operations, replacement metadata, active/failed/disabled/rolled-back route state, route events, routed invocations, and terminal controls from server-owned catalog/binding/route facts. Dedicated high-level route-story cards remain product polish after live testing, not a routing prerequisite. |
| Tests/stress harness | 8 | partial | 7 | Backend lifecycle tests and static invariants prove the first route. Simulator/live Tron stress tests are the next practical validation layer, not another foundation scorecard. |
| Minimal-engine guardrails | 4 | passed | 4 | Kernel/governance operations remain non-routable and no fallback/legacy paths return. Route operations are governance-locked and do not create package-manager, network, deploy, or raw-material side effects. |

## Runtime Route Model

The dispatcher has one route seam today:

```text
capability::execute(git_status)
  -> scoped capability route lookup
       no active route -> return built-in projection
       active route -> verify route/binding/candidate refs
                    -> verify lifecycle/runtime refs and enabled state
                    -> project supervised module-runtime provider-safe output
                    -> emit route event
                    -> return routed projection with dynamicReplacement evidence
       unsafe route -> emit failed_closed route event
                    -> return route failure without built-in success fallback
```

This is deliberately not a domain-specific module adapter executor. The route
resolver only chooses whether a governed route exists and whether it is safe to
invoke the supervised module-runtime projection boundary. It fails closed if
route records are stale, terminal, wrong-scope, missing authority evidence,
missing referenced records, lifecycle/runtime refs are stale or mismatched, or
the provider-safe projection is unsafe.

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

## Practical Live-Test Work

The foundational runtime route is complete for the first safe read-only target.
The next work should be practical live testing rather than another foundation
plan:

- Run Tron through the full `git_status` replacement workflow from the app:
  inspect readiness, record candidate, shadow, approve, activate, invoke,
  explain, disable, and roll back.
- Use the failures from that workflow to decide which cockpit/session briefing
  polish is necessary for user comprehension.
- Add the next adapter only after the first route proves operational in live
  sessions. Write operations, network adapters, package managers, dependency
  restoration, and production deployment remain out of scope until separate
  governed trials prove those contracts.
