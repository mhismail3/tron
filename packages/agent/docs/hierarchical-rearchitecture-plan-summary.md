# Hierarchical Rearchitecture Plan Summary

Status: `completed`

This artifact summarizes the external operator-authored HRA handoff plan that
seeded the hierarchical rearchitecture campaign. It preserves the campaign's
source intent in-repo so current provenance does not depend on any Downloads
file or local machine path. The source plan was human-authored by the operator
for this branch; the adopted implementation state is the in-repo scorecard,
evidence manifest, inventory artifacts, static gates, commits, and ledger rows.

## Campaign Intent

The HRA campaign followed the primitive teardown and primitive code cleanup. Its
goal was to make the repository tree read like the architecture:

- every folder is an ownership boundary with a reason to exist;
- Rust server modules are grouped by app, transport, engine, domain, and shared
  foundation/protocol ownership;
- iOS production and test code are grouped by feature and mirrored test
  ownership rather than broad technical buckets;
- Mac wrapper code is organized by wrapper feature boundaries;
- scripts, README, generated projects, docs, inventories, and scorecards move
  with the architecture;
- old internal paths, compatibility shims, old-path wrappers, alias modules, and
  stale path documentation are removed instead of preserved.

## Required Proof Shape

The plan required a scorecard-driven campaign with red static gates before the
major moves, followed by implementation checkpoints that update code, tests,
docs, generated projects, evidence, inventories, commits, and ledger records
together. Completion required all scorecard rows to be closed, all static gates
to pass, live docs to point at current paths, and the repository to retain no
dead compatibility surface created by the moves.

## Current Artifacts

The live HRA artifacts are:

- `packages/agent/docs/hierarchical-rearchitecture-scorecard.md`
- `packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md`
- `packages/agent/docs/hierarchical-rearchitecture-inventory.md`
- `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-ios-current-ownership-map.tsv`
- `packages/agent/docs/hierarchical-rearchitecture-ios-project-map.md`
- `packages/agent/tests/hierarchical_rearchitecture_invariants.rs`

The two ownership-map TSVs describe the current tracked tree and current owners.
They are not historical old-to-new lineage maps. Historical move evidence remains
in the evidence manifest and commit history.

## Closeout State

HRA is completed. AHA-9 refreshed this summary and the inventory gates so a
completed HRA scorecard cannot retain `pending`, `running`, `blocked`,
`failed_unfixed`, or `deferred_to_successor` rows in the current inventories.
