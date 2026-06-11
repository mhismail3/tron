# Self-Adapting Agent Promotion Governance Scorecard

Branch: `codex/self-adapting-agent-promotion-governance`
Baseline commit: `e781a6aef263327d82f666611cb975a71e67e2ee`
Status: **complete**
Current score: **100/100**

This scorecard hardens the next self-adapting-agent slice by making catalog
promotion an explicit, evidence-backed engine action. Generated artifacts,
capability definitions, materialized files, patch proposals, and generated UI
surfaces may be authored and reviewed as resources, but `engine::promote` now
widens catalog visibility only after validating decision, evidence, candidate,
scope, linkage, idempotency, and actor authority.

Invariant target:
`../tests/self_adapting_agent_promotion_governance_invariants.rs`.
Tracked test path:
`packages/agent/tests/self_adapting_agent_promotion_governance_invariants.rs`.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAPG-0 | Harness and Baseline | 7 | passed_after_fix | Verified the clean baseline, retained SAA closeout proof, added this scorecard/evidence pair, and wired `self_adapting_agent_promotion_governance_invariants` into local/GitHub closeout targets. |
| SAPG-1 | Promotion Source Inventory | 8 | passed_after_fix | Inventoried the promotion path across `engine::promote`, public `/engine` contracts, socket DTOs, catalog visibility mutation, resource definitions, resource wrappers, generated UI, and worker registration boundaries. |
| SAPG-2 | Promotion Contract | 10 | passed_after_fix | Internal and public promote schemas now require `functionId`, `targetVisibility`, `idempotencyKey`, `decisionResourceId`, non-empty evidence and candidate arrays, and `promotionReason`; responses echo validated governance refs. |
| SAPG-3 | Decision/Evidence Gate | 14 | passed_after_fix | `promotion_governance` requires a final accepted decision that approves the function and target, accepted verified evidence, scope-compatible resources, admin-like authority for system-scoped governance refs, and linked candidate/evidence chains before catalog mutation. |
| SAPG-4 | Authority Boundary | 11 | passed_after_fix | Workspace promotion requires matching workspace authority and `engine.promote.workspace`; system promotion requires admin-like actor authority and `engine.promote.system`; existing session ownership checks remain in force. |
| SAPG-5 | Candidate Compatibility | 10 | passed_after_fix | Promotion candidates are restricted to generated artifact, `capability_definition`, materialized file, patch proposal, generated UI, or agent rule resource kinds and must be linked to the decision/evidence chain. |
| SAPG-6 | Patch and File Promotion | 8 | passed_after_fix | Patch proposals and materialized files remain resource candidates; their lifecycle wrappers do not bypass `engine::promote` catalog governance or widen function visibility. |
| SAPG-7 | Generated UI Review | 7 | passed_after_fix | Generated UI remains a bounded `ui_surface` resource and a promotion candidate only by resource reference; no fixed product UI or auto-enable path was added. |
| SAPG-8 | Worker Non-Launch Boundary | 8 | passed_after_fix | Generated worker/capability definitions remain resource artifacts; runtime grants still exclude `engine::promote`, worker registration, trigger creation, and worker write authority. |
| SAPG-9 | Observability and Replay | 8 | passed_after_fix | Promotion responses and promoted function metadata carry redacted governance refs (`decisionResourceId`, evidence ids, candidate ids, and reason) so catalog changes can be replay-audited without embedding payloads. |
| SAPG-10 | Cross-Campaign Static Gates | 5 | passed_after_fix | PET/SAC/SAA invariants remain in the closeout set; static gates reject provider-visible promotion exposure, repo-managed skills, and worker auto-launch regressions. |
| SAPG-11 | Closeout | 4 | passed_after_fix | Code, tests, docs, README updates, scorecard evidence, personal-info guard, diff check, full CI validation, clean git state, and commit are completed together. |

## Boundary Statement

This slice does not add scheduling, deployment, automatic worker registration,
provider-visible `engine::promote`, product-specific generated UI, or a live
launch path. It only makes the existing catalog visibility promotion path
evidence-backed and target-authority checked.

## Governance Contract

`engine::promote` accepts only workspace or system targets. Workspace promotion
requires a non-empty `workspaceId` compatible with the actor context. System
promotion requires an admin-like actor and `engine.promote.system`. The
promotion payload must include a final accepted decision resource, at least one
accepted verified evidence resource, at least one compatible candidate resource,
and a non-empty reason. The validator runs before catalog mutation and the
mutation stamps redacted governance refs onto function metadata.
