# Modular Engine Maturity Scorecard

Last scored: 2026-05-19 on `next/modular-capability-engine`.

This scorecard turns the collapsed modular-engine target into a measurable
definition of done. The 100% state is not "all planned features exist"; it is
that the current engine is simple, resource-native, secure, inspectable,
recoverable, tested, and documented without duplicate state planes or legacy
compatibility paths.

## 100% Definition

Tron is at 100% when every executable path is a capability, every durable output
is a typed resource/version/link, every permission decision is grant-derived and
engine-owned, every operator view is a rebuildable projection or `ui_surface`,
every worker/package activation is inspectable and recoverable, and no legacy
route, fallback DTO, compatibility reader, product-shell duplicate, or parallel
state plane remains.

Collapsed substrate rules:

- workers invoke capabilities against resources under scoped grants;
- resources, resource versions, resource links, invocations, grants, workers,
  queues, leases, approvals, decisions, evidence, and generated UI resources are
  the durable substrate;
- control and iOS state are rebuildable projections only;
- package/source/policy/trust/audit tables are forbidden;
- `control::act`, dynamic UI catalogs, raw-scope authorization, fallback manifest fields,
  compatibility aliases, module action multiplexers, remote
  package fetch, and remote key discovery are forbidden.

## Scoring Rules

- `0%`: no current implementation or proof.
- `25%`: documented intent only.
- `50%`: implemented with targeted tests or static gates.
- `75%`: integration/failure coverage exists and docs are current.
- `100%`: complete evidence links, no known blockers, and no duplicate/legacy
  path.

## Rubric

| Axis | Points | Required Evidence For Full Credit |
|---|---:|---|
| Architecture simplicity | 15 | One canonical path per concept; no duplicate state planes; owners documented |
| Security/authority | 15 | Grant-owned authority; no raw scopes/client policy/secret leakage/child grant expansion |
| Resource model | 12 | Durable outputs and operator state are resource/version/link backed |
| Runtime reliability | 15 | Package activation, health, recovery, retry, cleanup, and failure paths covered end-to-end |
| Operator readiness | 12 | Control/generated UI explains status, lineage, risk, stale state, and next safe actions |
| Code comprehensibility | 12 | Large files split by concern; progressive docs map ownership and invariants |
| Test/proof strength | 12 | Static gates, focused tests, integration tests, absence tests, and failure-mode tests |
| Docs/operations | 7 | README, architecture docs, manual QA, and ledger match current behavior |

Current score: **95/100**.

## Axis Scores

### Architecture simplicity — 13/15

Evidence:

- `docs/collapsed-modular-engine-architecture.md` defines the worker,
  capability, resource, invocation, grant, event, control, UI, and module
  substrate.
- `packages/agent/src/engine/primitives/` owns first-party primitive workers.
- Static gates forbid control mutation multiplexers, old output-audit paths,
  public worker creation bypasses, and package/source/policy/trust/audit tables.
- Module trust review, scheduled trust audit, source trust, health/integrity,
  and activation runtime cleanup now have focused primitive submodules instead
  of living directly in the parent package-lifecycle file.
- The resource kernel is split into focused owners for public substrate types,
  built-in definitions, generic validation, version hashing, fixed-catalog
  `ui_surface` validation, and store implementations.
- Generated UI stored-surface/action validation now lives in
  `engine/primitives/ui/validation.rs`; the parent UI primitive remains
  registration, dispatch, and authoring coordination.

Blockers:

- `engine/primitives/module.rs` still owns activation lifecycle orchestration
  and shared helpers; those cross-cutting helpers need continued pressure
  against becoming a second policy layer.
- Some older domain and iOS product-shell surfaces remain deferred pending
  proof-driven removal.

Next action:

- Continue proof-driven removal/domain audits and keep lifecycle helpers narrow
  as package behavior matures.

### Security/authority — 14/15

Evidence:

- `grant::*` is the authority substrate, with child grant narrowing and static
  gates against `authorityCeiling` fallback.
- `engine/tests/grant_authority.rs` now proves child grants cannot expand
  capabilities, namespaces, authority labels, resource kinds/selectors, file
  roots, network policy, risk, budget, expiry, or approval; rejected grants fail
  before handler execution or produced-resource bookkeeping.
- Module package activation validates package source policy, grants, worker
  registration, risk, visibility, file/network bounds, and trust state before
  activation.
- Adversarial package manifest tests now cover duplicate function ids, unsafe
  local-process command refs, unsupported visibility, and raw secret-like values
  before `worker_package` persistence.
- Source-trust and health/integrity policy code now has focused ownership plus
  static gates that keep it out of the parent lifecycle coordinator and forbid
  parallel package/source/policy/trust/audit/health tables.
- `ui::submit_action` executes only stored canonical actions from validated
  `ui_surface` versions, and tests prove invalid input or stale target
  revisions fail before child invocation.

Blockers:

- `authority_scopes` still exist as audit/derived labels and need continued
  protection from becoming permission truth.
- More exhaustive property coverage is still useful for large selector/template
  cross-products, but the current deterministic adversarial cases now cover the
  highest-risk boundaries.

Next action:

- Add deeper projection/operator consequence tests without creating client-side
  policy or new control-plane state.

### Resource model — 12/12

Evidence:

- Artifacts, goals, claims, evidence, decisions, generated UI surfaces,
  materialized files, worker packages, module configs, activation records, and
  agent results are registered resource kinds.
- Module trust review, source trust, policy audit, conformance, recovery, and
  scheduled trust audits write `decision` and `evidence` resources instead of
  adding tables.
- `engine/tests/resource_kernel.rs` now characterizes built-in resource kinds,
  trust link relations, invalid-payload rejection, stale CAS rejection,
  non-current damaged versions, unsupported links, materialized-file output
  refs, malformed/wrong-kind `resourceRefs`, failed output-contract persistence,
  and the absence of the retired output-audit trace projection.

Blockers:

- No current blocker for the converted resource-backed substrate. Older domain
  and product-shell audits remain cleanup work, not a competing durable output
  model.

Next action:

- Audit deferred domain outputs and remove or convert remaining non-resource
  durable state.

### Runtime reliability — 15/15

Evidence:

- Targeted module tests cover package registration, local-process activation,
  source verification, signature verification, approval, conformance, health,
  integrity, recovery, upgrade, rollback, quarantine, trust review, and
  scheduled audits.
- Integration coverage exercises a real local-process package activation,
  health check, disable path, and cleanup.
- Trust-audit status, duplicate due-bucket enqueue, completed-bucket detection,
  missed-window reporting, schedule expiry, and advisory retention review are
  covered by focused tests.
- Activation runtime cleanup tests now cover spawn failure, missing worker
  registration after spawn, over-broad registered capabilities, activation
  persistence failure after spawn, duplicate activation replay, manual recovery
  when stop cleanup fails, and leaked grant/worker diagnostics.
- Queue-backed local-process activation now has a fail-once retry test proving
  existing queue backoff can retry a transient runtime failure without duplicate
  grants, workers, activation versions, or queue completion state.
- The Unix local-process integration path runs two activate -> health -> disable
  cycles with real `worker::spawn` / `sandbox::stop_spawned_worker`, proving no
  volatile worker or active activation grant remains after either cycle.

Blockers:

- Very long-running soak, interrupted worker process exits, and registration
  timeout scenarios still need broader runtime coverage, but the current
  activation/health/disable/retry/recovery substrate has focused and e2e proof.

Next action:

- Add targeted interruption/timeout tests only after the worker lifecycle
  protocol has explicit timeout fixtures.

### Operator readiness — 10/12

Evidence:

- `control::snapshot` and `control::inspect` expose workers, capabilities,
  grants, resources, invocations, module package refs, source trust summaries,
  activation refs, and generated UI refs.
- `ui::surface_for_target` authors package, activation, decision, worker, grant,
  resource, and integrity surfaces with stored canonical actions.
- `module::trust_audit_status` explains schedule lifecycle, current due bucket,
  queued/completed buckets, missed windows, latest evidence refs, affected refs,
  and retention warnings without adding status state.
- Generated trust-audit schedule surfaces expose canonical status, run,
  retention-review, and expiry actions.
- `module::inspect_package` now reports activation cleanup/recovery status,
  leaked grant refs, leaked worker refs, latest recovery evidence refs, and
  canonical next actions when activation cleanup is incomplete.

Blockers:

- Operator surfaces do not yet fully explain exact next-safe-action
  consequences, retention cleanup execution, or all stale-action failure causes
  across the iOS Engine Console.

Next action:

- Carry the new runtime diagnostics into any future Engine Console refinements
  without adding client-side policy.

### Code comprehensibility — 12/12

Evidence:

- Generated UI tests and trust-review tests now have focused test modules.
- Trust-review and scheduled-audit implementation are split into dedicated
  module primitive submodules.
- Progressive module docs explain the primitive substrate.
- Activation cleanup now flows through one internal diagnostic helper instead of
  ad hoc grant revoke / worker disconnect branches in each failure path.
- Activation runtime helper implementations and projection helpers now live in
  `engine/primitives/module/activation_runtime.rs`; the parent module remains a
  registration and lifecycle orchestration surface.
- `engine/resources/mod.rs` is a small facade with stable re-exports; focused
  resource submodules now make ownership visible before reading implementation
  details.
- `engine/primitives/ui/validation.rs` owns stored-surface diagnostics,
  stale/expired/damaged checks, action target validation, and template checks.
- Resource/materialization tests were moved out of the monolithic engine test
  file into `engine/tests/resource_kernel.rs`.
- `engine/primitives/module/source_trust.rs` now owns source registration,
  signature verification, source approvals, policy audit, trust inspection,
  renewal/rotation/expiry, reconciliation, and revocation enforcement.
- `engine/primitives/module/health_integrity.rs` now owns health checks,
  integrity verification, conformance evidence, and recovery entrypoint logic.
- Module activation tests are split into source-trust, health/integrity,
  trust-review, and lifecycle/runtime groups while sharing one fixture boundary.

Blockers:

- Some older domain tests remain broad string scans and should gradually become
  more ownership-specific.

Next action:

- Continue turning broad string scans into subsystem-specific proof gates.

### Test/proof strength — 12/12

Evidence:

- Full Rust CI covers formatting, compile check, clippy, 5k+ library tests,
  integration tests, DB path guards, and threat-model invariant gates.
- Static gates enforce absence of legacy surfaces and forbidden state planes.
- Focused tests now prove trust-audit status is projection-only, retention
  review is evidence-only, schedule expiry uses canonical CAS/evidence, and host
  enqueue does not backfill missed buckets.
- Static gates now require the activation runtime ownership boundary and reject
  helper implementations drifting back into `module.rs`.
- Queue retry and real local-process soak tests cover transient runtime failure,
  retry, cleanup, and repeated activation/disable cycles.
- Static gates now require the resource-kernel submodule split, fixed
  UI-surface payload validation ownership, and generated UI action-validation
  boundary.
- Static gates now require the module source-trust and health/integrity
  ownership boundaries and the matching focused module activation test files.
- Focused resource and generated-UI tests cover resource-kernel invariants,
  UI payload bounds, raw secret/local-file rejection, stale/discarded surface
  action rejection, and stable resource-backed output refs.
- Focused grant, manifest, resource-ref, and generated UI hardening tests now
  prove malformed/adversarial inputs fail in the owning subsystem before
  handler execution, package persistence, child invocation, or produced-ref
  bookkeeping.

Blockers:

- The maturity score needs continued calibration as more subsystems are audited.
- iOS generated UI tests only need to run when Swift/project files change, so
  server-only changes still rely primarily on DTO stability.

Next action:

- Add subsystem-specific proof gates for the remaining large module source-trust
  and health/integrity paths.

### Docs/operations — 7/7

Evidence:

- `README.md`, `docs/collapsed-modular-engine-architecture.md`,
  `docs/modular-engine-cleanup-audit.md`, and
  `docs/modular-engine-next-phase-plan.md` reflect the current substrate.
- `docs/module-package-trust-operations.md` documents the local package trust,
  audit, revocation, and cleanup operator lifecycle.
- Ledger entries record durable modular-engine checkpoints.
- The scorecard is updated with the trust-audit reliability evidence and next
  runtime-stress target.
- Runtime cleanup/recovery diagnostics and manual-recovery semantics are now
  documented in the package trust operations guide and next-phase plan.
- The activation-runtime ownership split, retry proof, and real local-process
  soak evidence are reflected in the cleanup audit and next-phase plan.
- The resource-kernel split and generated-UI validation boundary are reflected
  in the cleanup audit and next-phase plan.

Blockers:

- The scorecard needs to be updated every maturity checkpoint.

Next action:

- Keep updating this scorecard with every cleanup/hardening checkpoint.
