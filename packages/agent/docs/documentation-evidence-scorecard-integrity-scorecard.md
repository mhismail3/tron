# Documentation / Evidence / Scorecard Integrity Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

This scorecard closes the current-lineage Documentation / Evidence / Scorecard
Integrity slice on branch
`codex/documentation-evidence-scorecard-integrity-current`. The branch was
created from `687dc1e1f4b51701452f2ba25c92f34bc018a950` (`Harden repo hygiene
automation`). The older `codex/documentation-evidence-scorecard-integrity`
branch remains stale branch quarry-only evidence at
`f931c3126a2ee62940f42512278715c9c65c2079` and was not merged, cherry-picked,
or copied wholesale.

The goal is active documentation/evidence integrity: living docs describe
current behavior, closed scorecards are arithmetically exact and companioned by
evidence, inventories classify every retained boundary, local/GitHub static
gate lists stay in parity, and another thread can continue from durable
artifacts without chat history.

| Row | Name | Weight | Status | Evidence |
| --- | --- | ---: | --- | --- |
| DESI-0 | Baseline, lineage, and stale-branch quarantine | 5 | passed | Verified `687dc1e1f4b51701452f2ba25c92f34bc018a950` is an ancestor of HEAD, created the `-current` branch from the DXRHA baseline, recorded stale `codex/documentation-evidence-scorecard-integrity` as quarry-only, and audited active closeout artifacts before edits. |
| DESI-1 | Whole documentation/evidence artifact inventory | 10 | passed | Added narrative and TSV inventories covering README, AGENTS, local/GitHub gates, PR template, platform docs, every retained scorecard/evidence/inventory artifact, invariant targets, predecessor inventory rows, and historical/quarry classifications. |
| DESI-2 | Active docs truthfulness and present-tense closure | 10 | passed | Corrected active README and engine module wording from cleanup-in-progress language to present-tense retained behavior; historical evidence manifests remain classified instead of rewritten. |
| DESI-3 | Evidence command provenance and result integrity | 12 | passed | Added a DESI invariant that requires retained scorecards to have companion evidence manifests, concrete command results or source-grounded rationale, and no generic recorded-later evidence placeholders. |
| DESI-4 | Scorecard arithmetic and status integrity | 10 | passed | Added static parsing for every retained scorecard, requiring exact 100-point totals, continuous numeric rows, closed statuses, 100/100 status text, and companion evidence. |
| DESI-5 | Inventory coverage and predecessor cross-index integrity | 10 | passed | Added DESI rows to predecessor inventories and a DESI inventory guard that checks schema, row-to-scorecard coverage, tracked paths, classifications, and predecessor inventory references. |
| DESI-6 | README and progressive-disclosure docs sync | 8 | passed | Updated README living-doc and testing maps, PR checklist, HRA ownership summary, and engine module docs so active docs match the current source and static-gate surface. |
| DESI-7 | Static-gate/local-GitHub wiring and closeout target parity | 8 | passed | Wired `documentation_evidence_scorecard_integrity_invariants` into `scripts/tron.d/quality.sh` and `.github/workflows/ci.yml`; the invariant parses both lists and requires identical order. |
| DESI-8 | Stale/open-loop/future-tense residue guards | 10 | passed | Added source-backed guards against stale active cleanup language, recorded-later evidence placeholders, unresolved scorecard statuses, missing command provenance, and deploy automation residue in local/GitHub quality docs. |
| DESI-9 | Branch, handoff, and remote pickup hygiene | 7 | passed | Scorecard, evidence, and inventory record current branch, baseline commit, stale branch quarantine, `git status --short`, and pickup rules for another thread without chat history. |
| DESI-10 | Broad verification and final closeout | 10 | passed | Focused DESI and predecessor invariant targets, broad local CI, personal-info guard, iOS XcodeGen drift check, whitespace check, ignored-file audit, and clean status proof are recorded in the evidence manifest. |

## Closed Findings

- Active README prose still described the iOS shell and primitive substrate as
  cleanup work in progress. The current source and completed
  IOSTC/PCC/TPC/SOL/CSD/SACB/ODA/DSEMD/PERF artifacts show those are closed
  surfaces, so the README now states current behavior in present tense.
- The HRA inventory summary had predecessor rows for later slices but only
  named the refresh chain through PMBD. It now names PERF, CPE, RIURD, IOSTC,
  DXRHA, and DESI refreshes.
- Local and GitHub closeout target lists were already parser-guarded by DXRHA.
  DESI extends that proof by adding itself to both lists and preserving exact
  order.

## Historical Evidence Policy

Historical evidence manifests can retain old red/green failures, old branch
names, old cleanup terms, and old open-row wording when the text is clearly
part of command provenance. Active current docs, scorecards, inventories,
README sections, local/GitHub quality docs, and PR review docs must describe
the current state and may not use unresolved closeout placeholders.

## Handoff

Use branch `codex/documentation-evidence-scorecard-integrity-current`. Treat
`codex/documentation-evidence-scorecard-integrity` at
`f931c3126a2ee62940f42512278715c9c65c2079` as quarry-only. Pickup should run
`git status --short`, then rerun
`cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
before editing documentation/evidence/scorecard/static-gate surfaces so another
thread can continue without chat history.
