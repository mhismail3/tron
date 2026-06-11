# Self-Adapting Agent Successor Teardown Cleanup Inventory

Status: Source teardown in progress; current checkpoints tighten
provider-visible resource authorship, activation bundle metadata naming, worker
activation grant filesystem authority, trigger launch timing, and source-prove
bundle handoff, orchestration process-record retention, and schedule state/tick
retention, the public transport boundary, and the durability resource
substrate, plus the provider/execute, invocation-host governance, and primitive
surface boundaries, external-worker runtime lifecycle, and engine catalog/module
export boundary. The execute child grant is now source-proved operation-scoped:
direct model targets keep target-only authority, and only the retained
`capability::execute` resource/state operations receive nested substrate
capabilities. The final test-quality cluster is source-proved and the SAA
authorship fixture grant no longer preserves broad state authority; the TSV now
has no remaining `simplify` classifications. Later SAASTC rows remain open
until full closeout verification runs.

Scorecard: [`self-adapting-agent-successor-teardown-cleanup-scorecard.md`](self-adapting-agent-successor-teardown-cleanup-scorecard.md)

Evidence manifest: [`self-adapting-agent-successor-teardown-cleanup-evidence-manifest.md`](self-adapting-agent-successor-teardown-cleanup-evidence-manifest.md)

Machine-readable inventory: [`self-adapting-agent-successor-teardown-cleanup-inventory.tsv`](self-adapting-agent-successor-teardown-cleanup-inventory.tsv)

## Scope

This inventory covers every tracked file changed by
`git diff --name-status b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7..HEAD`, plus
the cleanup harness files added for this pass. The initial classification is a
triage decision for teardown work, not final proof of retention.

## Classification Values

- `retained`: required cleanup harness or closeout wiring that remains valid in
  Phase 1.
- `simplify`: source, tests, or docs that require source inspection before a
  retained primitive contract can be claimed.
- `remove`: code or docs expected to disappear unless source inspection proves a
  real retained primitive invariant. No Phase 1 row uses this final action yet.
- `docs-only`: evidence or README material that must stay truthful but is not a
  runtime contract.
- `predecessor-bookkeeping`: older campaign artifacts changed by successor work;
  these must be synchronized without preserving successor cruft.

## Current Classification Counts

- `retained`: 100
- `docs-only`: 31
- `predecessor-bookkeeping`: 23
- `simplify`: 0

## Phase 1 Boundaries

The TSV must have no missing owner, action, or rationale fields. Source teardown
must update it whenever a file is removed, simplified, or promoted from
`simplify` to `retained`. Final closeout must leave no row whose action still
defers source proof.
