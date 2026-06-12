# Developer Experience Repo Hygiene Automation Scorecard

Status: **closed**

Current score: **100/100**

Passing threshold: **100/100**

Base commit: `3cec727e19505aa4c58a18bcc4e54560c6829cce`

Branch: `codex/developer-experience-repo-hygiene-automation`

## Scope

DXRHA hardens the contributor workflow: setup, dev server, tests, generated
projects, docs, inventories, local/GitHub gates, branch/worktree handoff,
ignored-file hygiene, and production automation safety. This is repo hygiene,
not feature work.

## Scorecard

| Row | Name | Weight | Status | Evidence |
|---|---|---:|---|---|
| DXRHA-0 | Harness, Base, and Scope Control | 5 | passed | Branch/base verified clean before edits; final work remains on `codex/developer-experience-repo-hygiene-automation` from base `3cec727e19505aa4c58a18bcc4e54560c6829cce`. |
| DXRHA-1 | Contributor Workflow Inventory | 8 | passed | `developer-experience-repo-hygiene-automation-inventory.md` and `.tsv` were created before source edits and now cover 60+ workflow rows. |
| DXRHA-2 | Setup and Dev Server UX Discipline | 10 | passed_after_fix | `CONTRIBUTING.md` now documents `scripts/tron dev --stop`; README now describes foreground dev-server build/run behavior. |
| DXRHA-3 | Script Dispatch, Help, and Error Consistency | 10 | passed | DXRHA invariant verifies touched shell syntax, script dispatch markers, and contributor docs alignment. |
| DXRHA-4 | Generated Artifact Determinism | 10 | passed | iOS tracked project drift and Mac ignored generated-project policy were verified with XcodeGen. |
| DXRHA-5 | Local and CI Target Parity | 12 | passed_after_fix | `scripts/tron ci test` and GitHub static-gates now include the same named closeout target set, including DXRHA. |
| DXRHA-6 | Tracked Ignored and Stale Artifact Hygiene | 10 | passed | `git ls-files -ci --exclude-standard` returned no tracked ignored files. |
| DXRHA-7 | Branch, Push, and Worktree Handoff Cleanliness | 8 | passed | Branch/worktree handoff assumptions are inventoried; no auto-push, auto-PR, or deploy automation was added. |
| DXRHA-8 | README and Progressive Disclosure Accuracy | 10 | passed_after_fix | README, CONTRIBUTING, living-docs links, and predecessor inventories were synchronized with actual workflow behavior. |
| DXRHA-9 | Automation Safety Boundaries | 9 | passed | Static guards verify no production deploy automation expansion, no repo-managed `packages/agent/skills/`, and no broad `~/.tron` deletion guidance. |
| DXRHA-10 | Evidence, Adversarial Audit, Clean State, and Commit | 8 | passed | Required command matrix passed; evidence manifest records concrete results and residual risk. |

Total weight: **100**

## Required Artifacts

- `packages/agent/docs/developer-experience-repo-hygiene-automation-scorecard.md`
- `packages/agent/docs/developer-experience-repo-hygiene-automation-evidence-manifest.md`
- `packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.md`
- `packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.tsv`
- `packages/agent/tests/developer_experience_repo_hygiene_automation_invariants.rs`

## Closeout Criteria

DXRHA is closed at 100/100 because all rows are passed, the evidence manifest
records concrete command results, local and GitHub gates run the DXRHA invariant
target, generated project policy is verified, tracked ignored files remain
absent, and the work is ready to commit on the implementation branch.
