# Off-Plan Successor Teardown Cleanup Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/off-plan-successor-teardown-cleanup`
Base commit: `e4a76da64` (`Harden storage migration discipline`)
Audited off-plan range: `e781a6aef..2da96a848`

Evidence manifest:
[`off-plan-successor-teardown-cleanup-evidence-manifest.md`](off-plan-successor-teardown-cleanup-evidence-manifest.md)

Inventory:
[`off-plan-successor-teardown-cleanup-inventory.md`](off-plan-successor-teardown-cleanup-inventory.md)
and
[`off-plan-successor-teardown-cleanup-inventory.tsv`](off-plan-successor-teardown-cleanup-inventory.tsv)

Invariant target:
[`../tests/off_plan_successor_teardown_cleanup_invariants.rs`](../tests/off_plan_successor_teardown_cleanup_invariants.rs)

## Scope

This cleanup audits the successor/worker commits between `e781a6aef` and
`2da96a848`, removes off-plan worker activation, governed process launch,
trigger autostart, schedule scanning/dispatch, SAASTC retention tests, and
future-feature docs, and keeps only primitive-engine infrastructure that already
belonged to the pre-range boundary or later original-list storage work.

It does not add product features, public `/engine` storage/worker surfaces,
provider-visible tools, repo-managed skills, iOS settings, scheduler/autostart
behavior, launchd or SMAppService behavior, deploy automation, or production
service-manager changes.

## Original-List Alignment

Attachment parsed:
`<codex-home>/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt`.

Completed by the attachment at handoff time: primitive engine teardown,
primitive code cleanup/reorganization, ultimate final meta-pass documentation
cleanup, True Modularity, Determinism and Replayability, Failure Semantics,
State Ownership and Lifecycle, Concurrency and Scheduling Discipline, and SACB
except for the delegated `engine::invoke` budget-ordering remediation.

Completed in the current base after that handoff: SACB remediation, Observability
Diagnostics Auditability, and Data Integrity Storage Evolution Migration
Discipline.

Remaining original-list slices after this cleanup remain: Public Protocol / API
Contract Discipline, Provider / Model Boundary Discipline, Performance /
Resource Governance, Configuration / Profile / Environment Discipline, Release /
Install / Upgrade / Rollback Discipline, iOS Thin Client / Generic Runtime
Shell, Developer Experience / Repo Hygiene / Automation, Documentation /
Evidence / Scorecard Integrity, and Self-Sufficient Agent Runtime Readiness as a
readiness audit only.

The removed worker activation/orchestration/schedule commits are not converted
into original-list slices.

## Scenario Ledger

| Row | Name | Weight | Status | Closure requirement |
| --- | --- | ---: | --- | --- |
| OPSTC-0 | Harness | 5 | passed_after_fix | Cleanup scorecard/evidence/inventory/invariant strategy is established and wired only as a useful static guard. |
| OPSTC-1 | Original-list alignment | 10 | passed_after_fix | Attachment is parsed; original-list completed/remaining slices are recorded; cleanup does not invent new original slices. |
| OPSTC-2 | Off-plan history inventory | 10 | passed_after_fix | Every file changed from `e781a6aef..2da96a848` is inventoried with action and rationale. |
| OPSTC-3 | Successor surface pruning | 15 | passed_after_fix | Provider/public/iOS/settings/deploy/skill/scheduler/autostart/worker surfaces not needed for primitive teardown are removed or proven absent. |
| OPSTC-4 | Engine primitive necessity | 15 | passed_after_fix | Retained engine code is minimal, internally bounded, authority-scoped, and required by primitive infrastructure; unnecessary worker/self-adapting code is deleted. |
| OPSTC-5 | Durable-state/data cleanup | 8 | passed_after_fix | No unused schemas, resources, migrations, replay rows, queues, ledgers, or storage artifacts remain solely for off-plan future features. |
| OPSTC-6 | Docs/evidence truthfulness | 10 | passed_after_fix | README, scorecards, inventories, and evidence do not describe future feature work as active primitive teardown. Historical evidence is clearly historical. |
| OPSTC-7 | Test quality cleanup | 10 | passed_after_fix | Tests guard retained primitives, not deleted ambitions; stale/gamed/static-only cruft tests are removed or rewritten. |
| OPSTC-8 | Predecessor invariant preservation | 10 | passed_after_fix | PET/PCC/TPC/HRA/Determinism/Failure/State/CSD/SACB/ODA/DISEMD invariants still pass and do not depend on off-plan cruft. |
| OPSTC-9 | Closeout | 7 | passed_after_fix | Focused verification, full CI, personal-info guard, XcodeGen drift check, diff checks, clean status, commit, and residual-risk note are recorded. |

Total weight: **100**

## Retention Decision

Retained: generic worker catalog definitions, loopback external-worker protocol,
trigger runtime, queue/resource/stream/state/grant/storage primitives, SAA
authorship resource types that predate the off-plan range, SACB/ODA/DISEMD
original-list hardening, and the new OPSTC static guard.

Removed: `worker::issue_activation`, `worker::launch_activation`,
`worker::launch_from_trigger`, worker activation resources, worker process
orchestration, schedule plans/ticks/scan state, activation bundle vault, SAA
successor worker invariant targets, SAASTC prove-retention harness, and active
docs that described those future worker features as retained primitive teardown.
