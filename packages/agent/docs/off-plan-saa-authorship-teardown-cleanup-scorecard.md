# Off-Plan SAA Authorship Teardown Cleanup Scorecard

Status: **complete**

Current score: **100/100**

Total weight: **100**

Invariant target: `../tests/off_plan_saa_authorship_teardown_cleanup_invariants.rs`.

This remediation removes the off-plan Self-Adapting Agent Authorship (SAA)
implementation that landed in `e781a6aef263327d82f666611cb975a71e67e2ee`
before the original primitive-engine hardening meta-slices were complete. The
cleanup scope is intentionally narrow: remove completed/current SAA behavior and
claims, preserve source-proven primitive-engine work, and keep future
self-adapting-agent work as successor/readiness scope only.

| Row | Area | Weight | Status | Closeout proof |
| --- | --- | ---: | --- | --- |
| OPSAA-0 | Harness, Baseline, and Scope Control | 5 | passed_after_fix | Cleanup branch created from `e781a6aef`; scorecard, evidence manifest, inventory, TSV, invariant target, README links, and CI/local target wiring are added in this remediation. |
| OPSAA-1 | SAA Surface Inventory and Classification | 12 | passed_after_fix | Inventory classifies every `e781a6aef` SAA-added or SAA-modified surface as `delete`, `revert_to_pre_saa`, `retain_generic_preexisting`, or `retain_with_rewording`. |
| OPSAA-2 | Provider-Facing Execute Contract Re-narrowed | 12 | passed_after_fix | `capability::execute` provider schema and OpenAI clarification return to observe/state/file/process/trace/log/replay operations only. |
| OPSAA-3 | SAA Resource Operations Removed or Proven Generic | 12 | passed_after_fix | The SAA-only execute `resource_*` adapter is removed; the generic engine `resource::*` primitive substrate is retained as preexisting primitive-engine behavior. |
| OPSAA-4 | Agent Memory/Rule Runtime Substrate Removed or Reclassified Future-Only | 10 | passed_after_fix | `agent_memory` and `agent_rule` built-in resource definitions, namespace claims, grant kind allowances, and durability test requirements are removed. |
| OPSAA-5 | Static Gates, README, and CI Cleaned | 10 | passed_after_fix | Active SAA docs/tests are deleted, `self_adapting_agent_authorship_invariants` is removed from local/GitHub closeout lists, and README no longer presents SAA as completed current architecture. |
| OPSAA-6 | Predecessor Inventories and Counts Reconciled | 10 | passed_after_fix | HRA, PCC, TPC, and SACB inventories remove active SAA rows, add OPSAA cleanup rows/counts, and retain only source-proven predecessor work. |
| OPSAA-7 | Negative Guards Against SAA Resurrection | 12 | passed_after_fix | OPSAA invariant target rejects active SAA docs/tests, provider-visible `resource_*` operations, `agent_memory`/`agent_rule`, SAA CI target wiring, and completed/current SAA README or inventory claims. |
| OPSAA-8 | Regression Coverage for Retained Primitive Behavior | 10 | passed_after_fix | Existing targeted capability, durability, SACB, ODA, HRA, PCC, TPC, trace, and integration tests are run after cleanup to prove retained primitive behavior still works. |
| OPSAA-9 | Evidence, Broad Verification, and Clean Commit | 7 | passed_after_fix | Evidence manifest records exact closeout commands/results; full Rust CI, personal-info guard, iOS project drift check, diff hygiene, ignored-file check, and status checks are recorded before commit. |

## Retention Policy

Retained code must have source proof independent of the off-plan SAA feature.
The generic engine resource kernel and primitive `resource::*` worker are
retained because they predate `e781a6aef` and are covered by engine durability
tests. Provider-visible `resource_create`, `resource_update`, `resource_link`,
`resource_inspect`, and `resource_list` are removed because they were added by
`e781a6aef` as SAA execute-surface widening.

Future self-adapting-agent work is not implemented here. It belongs to a later
successor/readiness campaign after the original primitive-engine hardening
meta-slices close.
