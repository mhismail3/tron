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

Current score: **77/100**.

## Axis Scores

### Architecture simplicity — 10/15

Evidence:

- `docs/collapsed-modular-engine-architecture.md` defines the worker,
  capability, resource, invocation, grant, event, control, UI, and module
  substrate.
- `packages/agent/src/engine/primitives/` owns first-party primitive workers.
- Static gates forbid control mutation multiplexers, old output-audit paths,
  public worker creation bypasses, and package/source/policy/trust/audit tables.

Blockers:

- `engine/resources.rs`, `engine/tests.rs`, `engine/primitives/module.rs`, and
  `engine/primitives/ui.rs` still contain multiple concerns in large files.
- Several older domain and iOS product-shell surfaces remain deferred pending
  proof-driven removal.

Next action:

- Continue focused file splits and domain removal audits without changing public
  behavior.

### Security/authority — 12/15

Evidence:

- `grant::*` is the authority substrate, with child grant narrowing and static
  gates against `authorityCeiling` fallback.
- Module package activation validates package source policy, grants, worker
  registration, risk, visibility, file/network bounds, and trust state before
  activation.
- `ui::submit_action` executes only stored canonical actions from validated
  `ui_surface` versions.

Blockers:

- `authority_scopes` still exist as audit/derived labels and need continued
  protection from becoming permission truth.
- More fuzz/property coverage is needed for grant selectors, UI templates, and
  package manifests.

Next action:

- Add targeted property/failure tests for grant narrowing, resource selectors,
  secret redaction, and stale UI action rejection.

### Resource model — 10/12

Evidence:

- Artifacts, goals, claims, evidence, decisions, generated UI surfaces,
  materialized files, worker packages, module configs, activation records, and
  agent results are registered resource kinds.
- Module trust review, source trust, policy audit, conformance, recovery, and
  scheduled trust audits write `decision` and `evidence` resources instead of
  adding tables.

Blockers:

- Some older domain outputs and product-shell caches still need proof-driven
  audit for full resource-native coverage.

Next action:

- Audit deferred domain outputs and remove or convert remaining non-resource
  durable state.

### Runtime reliability — 12/15

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

Blockers:

- Long-running soak, repeated retry, interrupted worker, registration timeout,
  and cleanup-leak scenarios are not yet broad enough.
- The real local-process integration test has shown timeout sensitivity under
  full-suite load and needs hardening.

Next action:

- Add deterministic runtime stress tests around retries, worker registration
  timeout, leaked grants/workers, and recovery after interrupted activation.

### Operator readiness — 9/12

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

Blockers:

- Operator surfaces do not yet fully explain exact next-safe-action
  consequences, retention cleanup execution, or all stale-action failure causes.

Next action:

- Add richer operator diagnostics for runtime cleanup/recovery outcomes and
  stale generated UI action rejection.

### Code comprehensibility — 7/12

Evidence:

- Generated UI tests and trust-review tests now have focused test modules.
- Trust-review and scheduled-audit implementation are split into dedicated
  module primitive submodules.
- Progressive module docs explain the primitive substrate.

Blockers:

- Several large files still require careful splitting by ownership boundary.
- Some static tests are broad string scans and should gradually become more
  ownership-specific.

Next action:

- Continue splitting stable concerns into submodules and update progressive
  docs with each split.

### Test/proof strength — 11/12

Evidence:

- Full Rust CI covers formatting, compile check, clippy, 5k+ library tests,
  integration tests, DB path guards, and threat-model invariant gates.
- Static gates enforce absence of legacy surfaces and forbidden state planes.
- Focused tests now prove trust-audit status is projection-only, retention
  review is evidence-only, schedule expiry uses canonical CAS/evidence, and host
  enqueue does not backfill missed buckets.

Blockers:

- The maturity score needs continued calibration as more subsystems are audited.
- iOS generated UI tests only need to run when Swift/project files change, so
  server-only changes still rely primarily on DTO stability.

Next action:

- Add subsystem-specific stress and failure-mode gates for runtime cleanup and
  recovery.

### Docs/operations — 6/7

Evidence:

- `README.md`, `docs/collapsed-modular-engine-architecture.md`,
  `docs/modular-engine-cleanup-audit.md`, and
  `docs/modular-engine-next-phase-plan.md` reflect the current substrate.
- `docs/module-package-trust-operations.md` documents the local package trust,
  audit, revocation, and cleanup operator lifecycle.
- Ledger entries record durable modular-engine checkpoints.
- The scorecard is updated with the trust-audit reliability evidence and next
  runtime-stress target.

Blockers:

- Manual runtime-stress and cleanup-leak QA procedures remain incomplete.
- The scorecard needs to be updated every maturity checkpoint.

Next action:

- Add manual runtime-stress/cleanup QA docs and update this scorecard with every
  cleanup/hardening checkpoint.
