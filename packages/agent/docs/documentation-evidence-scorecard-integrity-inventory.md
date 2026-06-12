# Documentation Evidence Scorecard Integrity Inventory

Status: **inventory_built_pre_edit**

Base commit audited: `9ef779cf56c7a498921dec0782dea41cfbe17104`

Branch audited: `codex/documentation-evidence-scorecard-integrity`

Machine-readable inventory:
[`documentation-evidence-scorecard-integrity-inventory.tsv`](documentation-evidence-scorecard-integrity-inventory.tsv)

Full path:
`packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.tsv`.

This inventory was built before DESI source edits. It covers the retained
documentation, evidence, scorecard, inventory, README, contributor workflow,
static-gate, predecessor-inventory, and provenance surfaces named by the
original Documentation / Evidence / Scorecard Integrity slice.

## Surface Classes

| Class | Meaning |
|---|---|
| `scorecard` | Completed hardening scorecard rows, weight totals, status labels, and closeout text. |
| `evidence_manifest` | Command matrices, row evidence, source findings, blockers, and residual risks. |
| `inventory_doc` | Human-readable inventory summaries and status/provenance notes. |
| `inventory_tsv` | Machine-readable inventory rows consumed by static guards. |
| `desi_artifact` | Required DESI scorecard, evidence, inventory, TSV, and invariant target. |
| `readme_truth` | Root README living-doc map, static-gate list, testing section, and canonical workflow references. |
| `contributor_workflow` | Contributor guide and PR surfaces that explain tests/docs/evidence requirements. |
| `local_gate` | Local scripts or guards that enforce closeout target, personal-info, ignored-file, or command-matrix hygiene. |
| `github_gate` | GitHub workflow declarations that must stay in parity with local closeout targets. |
| `predecessor_inventory` | Retained predecessor inventories that must gain rows for new DESI artifacts once tracked. |
| `progressive_disclosure` | Source-adjacent docs and module maps that must remain truthful for touched areas. |
| `closed_artifact_policy` | Cross-artifact stale-marker, passed-claim, and cleanup-language rejection contracts. |
| `provenance_hygiene` | Redaction, path, personal-info, and chat-history-dependency boundaries. |

## Pre-Edit Findings

- Baseline status was clean, the worktree was on
  `codex/documentation-evidence-scorecard-integrity`, and `HEAD` was
  `9ef779cf56c7a498921dec0782dea41cfbe17104`.
- Local and GitHub named closeout targets are source-owned by
  `scripts/tron.d/quality.sh` and `.github/workflows/ci.yml`; DESI is not yet
  wired because the target does not exist at inventory time.
- Root README living-doc entries still use `active` wording for several
  scorecards whose scorecard/evidence artifacts are now closed.
- `ios-thin-client-generic-runtime-shell-inventory.md` retains
  `active_validation_pending` even though the ITC scorecard and evidence
  manifest are closed at 100/100.
- `public-protocol-api-contract-discipline-inventory.md` retains an old
  `blocked_pending_ios_runtime_validation` status even though the PPACD
  scorecard and evidence manifest are closed at 100/100.
- Completed artifacts broadly include command evidence, but DESI needs a
  cross-artifact guard so `passed`, `passed_after_fix`, `closed`, `complete`,
  and `100/100` claims remain traceable to concrete command or source evidence.
- Predecessor inventories must gain rows for DESI artifacts after those
  artifacts are tracked; the existing DXRHA guard already proves this pattern
  for HRA, PCC, and TPC inventories.
- Durable DESI evidence must use repo-relative paths or explicit redaction for
  local user/worktree paths and must not rely on conversation-only proof.

## Closeout Policy

DESI may create scorecard, evidence, inventory, and invariant artifacts; patch
stale documentation/evidence/inventory wording that is source-proven; add static
guards for evidence traceability, closed-artifact closure, target parity,
predecessor inventory coverage, ignored-file hygiene, and path/provenance
hygiene; and synchronize README and contributor references with actual behavior.

DESI must not add server APIs, public `/engine` surfaces, provider features,
scheduler/autostart behavior, product panels, repo-managed skills, deploy
automation, LaunchAgent or SMAppService ownership paths, iOS settings, or
successor-agent runtime features.
