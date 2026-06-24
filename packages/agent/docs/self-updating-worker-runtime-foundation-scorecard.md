# Self-Updating Worker Runtime Foundation Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Current implementation branch:
`codex/self-updating-worker-runtime-foundation-current`.
Baseline:
`4cb2387f1a872f9fabaf58bdd88330065113b914`
(`Close baseline before feature restoration`). This goal is the first
post-BPRC restoration slice and is limited to BPRC-FEATURE-06 foundation work.

Scope quarantine: SUWRF adds worker package lifecycle, local launch policy,
scoped worker-token derivation, conformance evidence, rollback records, and
generic resource/stream visibility. It does not restore MCP, skills, memory,
web/browser research, scheduler, subagents, prompt library, program execution,
fixed iOS product panels, provider-visible tool widening, or production deploy
behavior; later approved Phase 2 restorations must be tracked in the Phase 2
inventory and remain outside SUWRF's worker-lifecycle scope.

| Row | Name | Points | Status | Closure |
| --- | --- | ---: | --- | --- |
| SUWRF-0 | Baseline and scope | 5 | passed | Branch, baseline commit, BPRC lineage, and no-feature-restoration quarantine are recorded. |
| SUWRF-1 | Lifecycle ownership | 10 | passed | `domains::worker_lifecycle` owns package lifecycle separately from `/engine/workers` protocol hosting. |
| SUWRF-2 | Manifest contract | 10 | passed | `tron.worker_package.v1` validation covers identity, provenance, digest, local source root, argv launch, env allowlist, expected catalog entries, grants, conformance, and rollback. |
| SUWRF-3 | Authority and grants | 10 | passed | Apply functions require trusted actor kind, `worker.lifecycle.write`, and a derived non-bootstrap grant; launch derives a narrower worker grant and scoped token. |
| SUWRF-4 | Launch isolation | 10 | passed | Launch uses canonical local package roots, no-shell argv, `env_clear`, explicit env injection, one-time scoped worker token, and loopback endpoint handoff. |
| SUWRF-5 | Conformance gate | 10 | passed | Launch waits for matching worker, namespace claims, expected function owners, expected triggers, and optional exact-function checks before recording running state. |
| SUWRF-6 | Resource/event evidence | 10 | passed | Package, installation, proposal, launch-attempt, and conformance records are generic resources; every transition publishes `worker.lifecycle`. |
| SUWRF-7 | Rollback/failure semantics | 8 | passed | Launch failure and conformance failure update failed resource state, stop launched processes when needed, and avoid optimistic running state. |
| SUWRF-8 | Generic iOS visibility | 7 | passed | No Swift DTO or fixed panel expansion was required; generic resource and stream surfaces expose lifecycle state. |
| SUWRF-9 | Static gates | 10 | passed | `self_updating_worker_runtime_foundation_invariants` enforces artifact, source, no-sprawl, no-panel, launch/protocol separation, and target parity constraints. |
| SUWRF-10 | Docs/evidence/closeout | 10 | passed | README, module docs, scorecard, inventory, evidence manifest, static gates, focused tests, and final closeout commands are recorded. |

## Closure Verdict

The engine now has a minimal self-updating worker foundation: packages can be
proposed inertly, installed from an approved local root, enabled/disabled,
launched with a scoped worker token, conformance-checked against the live
catalog, stopped, retired, and audited through resources and streams. Future
capability restorations must enter through this lifecycle or through a more
specific successor that preserves the same authority, provenance, conformance,
rollback, and generic UI evidence boundaries.
