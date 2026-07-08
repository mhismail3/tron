# Minimal Kernel Self-Adaptation Hardening Scorecard

Status: **complete**

Current score: **100/100**

This capstone scorecard ties together the modularity, context-control, and
dynamic-replacement work into one minimal-kernel contract. It does not add a
new provider operation, runtime plane, approval bypass, package manager,
network installer, deploy path, or broad self-update behavior. Its purpose is to
make the final foundation explicit: Tron may self-adapt only by moving
replaceable behavior behind server-owned policy, evidence, route, visibility,
and rollback contracts. The engine remains minimal by keeping only the
irreducible trust substrate in kernel/governance ownership.

Source-backed artifacts:

- Machine inventory: `packages/agent/docs/minimal-kernel-self-adaptation-hardening-inventory.tsv`
- Evidence manifest: `packages/agent/docs/minimal-kernel-self-adaptation-hardening-evidence-manifest.md`
- Static invariant: `packages/agent/tests/minimal_kernel_self_adaptation_hardening_invariants.rs`
- Operation inventory: `packages/agent/docs/capability-modularity-inventory.tsv`
- Runtime route scorecard: `packages/agent/docs/capability-dynamic-replacement-scorecard.md`
- Context policy owner: `packages/agent/src/domains/context_control/mod.rs`
- Dynamic route owner: `packages/agent/src/domains/capability_binding/route.rs`

Provider-visible surface remains one tool: `capability::execute`.

## Goal Definition

The hardening goal is achieved only when all of the following are true and
source-backed:

1. Minimal kernel responsibilities are enumerated and intentionally
   non-replaceable.
2. Replaceable behavior is never routed by assertion alone; it must carry
   current evidence refs, exact authority, stale-version guards, provider-safe
   output proof, lifecycle/runtime proof, route events, and rollback/disable
   controls.
3. Context-management replacements cannot bypass survivor/exclusion policy,
   policy snapshots, context-control action records, or compact/clear boundary
   audit.
4. Cockpit/session visibility reads server-owned facts and can explain active,
   failed, disabled, and rolled-back adaptations without raw IDs or local-only
   truth.
5. The foundation is strict without becoming ceremony: the capstone adds no new
   runtime surface and only locks cross-scorecard invariants that already have
   source owners.

## Weighted Scorecard

| ID | Area | Weight | Status | Score | Acceptance |
|---|---|---:|---|---:|---|
| MKS-0 | Minimal kernel map | 18 | passed | 18 | Authority, transport, event log, resource custody, redaction, trace/replay/catalog, module governance, context policy, and route resolution are named as irreducible kernel/governance substrate. |
| MKS-1 | Replacement proof contract | 18 | passed | 18 | Candidate, shadow, binding, activation, route-event, runtime projection, stale-version, provider-safety, and rollback proofs are explicit and current-version guarded. |
| MKS-2 | Context policy contract | 14 | passed | 14 | Survivor/exclusion records and policy snapshots are server-owned, bounded, fail-closed, and required for future compaction summarizer replacement. |
| MKS-3 | Fail-closed route behavior | 12 | passed | 12 | Unsafe, stale, ambiguous, disabled, or missing-proof routes do not return built-in success as the replacement result. |
| MKS-4 | Visibility and explanation | 12 | passed | 12 | Engine Cockpit derives route stories, operation state, failed adaptations, terminal controls, and drill-downs from server-owned route/binding facts. |
| MKS-5 | Minimality guard | 10 | passed | 10 | No new model-facing tool, runtime plane, package/deploy behavior, or broad module hot-swap is introduced by the capstone. |
| MKS-6 | Static proof coverage | 10 | passed | 10 | Static invariants pin this capstone to the modularity and dynamic replacement scorecards plus the core source files that enforce them. |
| MKS-7 | Honest boundary | 6 | passed | 6 | The foundation proves the first scoped read-only `git_status` route and the replacement contract; it does not claim full autonomous self-update across all operations. |

## Minimal Kernel Map

| Substrate | Ownership | Why it stays minimal kernel/governance |
|---|---|---|
| Authority and grants | kernel | Every replacement needs exact authority; modules cannot own the authority resolver that decides whether they may run. |
| Transport framing | kernel | `/engine` authenticates and frames requests; domain behavior stays elsewhere. |
| Event/session log | kernel | Durable reconstruction and audit history must remain source truth. |
| Resource custody | kernel | Record-plane and module-produced evidence must pass through typed resources. |
| Redaction/provider safety | kernel | Provider-safe output cannot be delegated to the replacing module's best effort. |
| Trace/replay/catalog | kernel | The agent must be able to rediscover and replay what changed using server-owned facts. |
| Module governance | governance | Registry, authoring, validation, install, dependency, lifecycle, runtime, and capability binding govern replacement itself. |
| Context policy | record-plane custody | Survivors, exclusions, policy snapshots, and context-control actions are server-owned constraints that future replacement summarizers must consume. |
| Route resolution | governance | The dispatcher only chooses built-in versus governed route; it does not learn module behavior or mutate dispatch tables. |
| Cockpit visibility | read-only projection | User-facing adaptation state is derived from server facts, not local UI guesses. |

## Replacement Proof Contract

A replacement candidate is contractually valid only if the server can verify all
of the following before routing:

- Target operation is known and eligible by the capability modularity inventory.
- Candidate, binding, activation, shadow evidence, lifecycle, and runtime refs
  are exact, current, and scope-compatible.
- Authority constraints are exact, non-wildcard, and resource-scoped where a
  linked record is referenced.
- Provider-visible output is bounded and projected through server-owned
  provider-safety checks.
- The side-effect proof forbids package managers, network installs, production
  deploys, dependency restoration, raw local material, raw grants, raw authority
  IDs, debug payloads, and repo-managed skills.
- Route events record activation, routed invocation, failed-closed outcomes,
  disable, and rollback.
- Rollback and disable controls exist before activation.

This is verification, not trust in the module author. Candidate records,
route bindings, activations, runtime projections, and context policy snapshots
carry the proofs; route lookup rejects stale or missing proofs.

## Context Policy Contract

The context-control plane owns the durable policy that a future compaction
strategy must obey:

- `context_survivor_record/list/disable` names provider-safe refs that must
  survive future context binding.
- `context_exclusion_record/list/disable` names provider-safe refs that must be
  omitted.
- `context_policy_snapshot` records the complete bounded active policy set and
  fails closed if the set cannot be projected safely.
- `context_control_compact` and runtime compaction record context-control
  action/audit refs before committing a compact boundary.

A future summarizer may be replaced; the context policy substrate may not be
bypassed.

## Honest Boundary

The current foundation is ready for practical live Tron stress testing of the
first governed replacement route and the surrounding ergonomics. It is not a
claim that Tron can safely replace every adapter today. Additional write,
network, package-manager, dependency, deployment, and broad module-code routing
must each earn their own governed trial using this same proof contract.
