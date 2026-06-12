# Documentation Evidence Scorecard Integrity Scorecard

Status: **closed**

Current score: **100/100**

Passing threshold: **100/100**

Base commit: `9ef779cf56c7a498921dec0782dea41cfbe17104`

Branch: `codex/documentation-evidence-scorecard-integrity`

## Scope

DESI hardens documentation, evidence, scorecard, inventory, static-gate, README,
and provenance integrity for the completed primitive-engine hardening artifacts.
It is a documentation/evidence integrity slice only; it does not add server APIs,
public `/engine` surfaces, provider behavior, scheduler/autostart behavior,
product panels, repo-managed skills, deploy automation, LaunchAgent/SMAppService
behavior, iOS settings, or successor-agent runtime features.

## Scorecard

| Row | Name | Weight | Status | Evidence |
|---|---|---:|---|---|
| DESI-0 | Harness, Base, and Scope Control | 5 | passed_after_fix | Branch/base/scope are recorded, DESI stayed docs-and-static-gate only, and no production/deploy path was invoked. |
| DESI-1 | Documentation and Evidence Inventory Completeness | 10 | passed_after_fix | Inventory pair was built before source edits, covers retained documentation/evidence surfaces, and is guarded for row shape and completeness. |
| DESI-2 | Closed Artifact State Integrity | 12 | passed_after_fix | Stale README, ITC inventory, and PPACD inventory state drift is patched and guarded. |
| DESI-3 | Evidence Claim Traceability | 12 | passed_after_fix | DESI evidence manifest records source findings, row evidence, and reproducible command evidence for closure claims. |
| DESI-4 | Scorecard Math and Row Closure Discipline | 10 | passed_after_fix | DESI invariant checks exact required row names, explicit row statuses, closed-state hygiene, and weights totaling 100. |
| DESI-5 | Inventory Coverage and Predecessor Synchronization | 10 | passed_after_fix | DESI artifacts are covered by HRA, PCC, TPC, and SACB predecessor inventories. |
| DESI-6 | README and Progressive Disclosure Truthfulness | 10 | passed_after_fix | README living-doc labels are synchronized with closed artifacts and the DESI target is linked. |
| DESI-7 | Future-Tense and Aspirational Cleanup Rejection | 8 | passed_after_fix | Static guard rejects stale open-loop wording in current closed summaries while preserving historical evidence records. |
| DESI-8 | Command Matrix Reproducibility | 8 | passed_after_fix | Required closeout commands are listed in the DESI evidence manifest with concrete pass results. |
| DESI-9 | Personal Info, Path, and Provenance Hygiene | 7 | passed_after_fix | DESI guard and personal-info closeout protect durable evidence from local path leakage or conversation-only proof. |
| DESI-10 | Adversarial Audit, Clean State, and Commit | 8 | passed_after_fix | Final guards require clean staged intent before commit and clean branch state after commit. |

Total weight: **100**

## Required Artifacts

- `packages/agent/docs/documentation-evidence-scorecard-integrity-scorecard.md`
- `packages/agent/docs/documentation-evidence-scorecard-integrity-evidence-manifest.md`
- `packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.md`
- `packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.tsv`
- `packages/agent/tests/documentation_evidence_scorecard_integrity_invariants.rs`

## Closeout Criteria

DESI is closed at 100/100. Closure requires all rows to pass, concrete command
results in the evidence manifest, local and GitHub gates running the DESI
invariant target, predecessor inventories covering the new artifacts, closed
artifacts rejecting stale open-loop markers, and a clean worktree after commit.
