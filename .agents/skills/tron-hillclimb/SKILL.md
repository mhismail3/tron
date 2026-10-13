---
name: tron-hillclimb
description: Improve one Tron metric against a frozen, maintainer-approved eval spec, one causal change per round, with a held-out guard and a runner-written verdict. Use when asked to hill-climb, or when a run is started for a named spec under tools/hillclimb/specs/.
---

# Hill-climb one metric

Apply [project rules](../../../AGENTS.md) and [performance](../tron-performance/SKILL.md).
The design and its limits live in [tools/hillclimb/README.md](../../../tools/hillclimb/README.md).
A spec authorizes measurement and candidate edits inside its `editable` paths;
it does not authorize merging, Gateway lifecycle actions or new eval specs.

## Before the first round

1. Claim the spec's tracking issue with `scripts/tron work start <issue>`; work
   only in the printed worktree. One spec per claim.
2. Read the spec. Do not edit it, its harness, tests or anything under `frozen`.
   A spec that looks wrong is a finding to report, never something to fix in the
   same run.
3. Run an A/A trial (`--base HEAD --candidate HEAD` is refused, so measure the
   spec's scenario twice on the base with `scripts/tron-profile` and
   `scripts/tron-profile compare`). If the noise bound on the primary metric is
   larger than `primary.min_effect`, stop and report: the eval cannot see a
   change you would keep.
4. A profiler failure (exit 5/6, busy, startup budget, event-loop-delay
   warnings) is plumbing, not a score. Report it with its evidence directory;
   retry once only after the host is quieter, never by raising timeouts.

## Each round

1. Attribute before editing: read the base run's per-topic metrics and
   `timeline.jsonl` for the **primary scenario only**. Never open held-out
   scenario logs; they exist to catch overfitting.
2. Make one causal change at its root, inside `editable`, with the owning docs
   updated. Respect `protected_behavior`: fewer frames bought by slower UI,
   dropped events, changed protocol shape or weaker diagnostics is not a win.
3. Commit it as one checkpoint and push.
4. Run `scripts/tron-hillclimb trial --spec <spec> --base <last kept> --candidate HEAD --out tmp/hillclimb-runs/<round>`.
   The runner, not you, decides: `keep` (exit 0), `revert` (3), `inconclusive`
   (4), harness failure (5). Do not reinterpret its verdict.
5. On `revert` or `inconclusive`, `git revert` the candidate commit (keep the
   history as evidence). On `keep`, the candidate becomes the next base.

## Stop

Stop at `budget.max_rounds`, at the wall-clock budget, after
`budget.max_stalled_rounds` rounds without a kept change, or at the first
harness failure that repeats. After a stall, do one reflection pass: sort the
remaining cost by cause (inherent, protocol-level, UX-protected, harness
artifact) and report it instead of trying smaller edits below the noise bound.

## Hand off

Push the branch, then post the result on the issue with
`scripts/tron work comment`: the kept commits, each `verdict.json` (primary
delta and noise bound, A/A drift, held-out and correctness results), rejected
hypotheses and protected-behavior judgments. Do not run `scripts/tron work
land`; the maintainer reviews and lands. Remove `tmp/hillclimb-runs/` worktrees
only through the runner (it removes its own on every exit).
