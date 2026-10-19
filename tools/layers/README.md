# Gateway layers

`scripts/tron layers` checks the Gateway's import graph against each module's
manifest `layer` and `dependsOn` ([plan §6.7 V5](../../docs/restructure/plan.md#67-structure-checkers-v5-v6-v8-v9-v10)).
It reports and is never wired into a hook, landing or queue. iOS and Mac have
no reference checker yet; their technique is a pending maintainer decision.

```bash
scripts/tron layers                 # compare with packages/gateway/layer-baseline.json
scripts/tron layers --update        # remove fixed entries (or write the first baseline)
scripts/tron layers --base <ref>    # bound the baseline by <ref>'s (default origin/main)
```

Exit 0: no violation beyond the baseline. Exit 1: problems, listed one per line.
Exit 2: usage error, ownership violations, an unowned program file (`git add`
and own it), or a missing compiler. None of these is ever reported as clean.

## Graph

Edges come from the pinned TypeScript compiler, not a text scan:
`tsc -p packages/gateway/tsconfig.json --noEmit --explainFiles`, run with
`scripts/tron-node`. Every reason a file is in the production program counts:
static, type-only, side-effect, re-export and dynamic imports. Type errors do not
stop the graph. Only edges between two `src/` files are read; tests and
test support are outside the production program and outside this check.
Gateway dependencies must be installed (`npm ci` in `packages/gateway`).

Module owners, layers and `dependsOn` come from `tools/ownership`; nothing here
re-derives ownership.

## Rules

For each pair of distinct modules A → B with at least one file edge:
- **upward**: B's layer number is higher than A's;
- **undeclared**: B is not in A's `dependsOn`. Declaring a dependency never
  legalizes an upward edge;
- **two-way**: B also imports A (recorded once per pair).

A rule's count is its number of file edges (a two-way pair counts once).

## Baseline

`packages/gateway/layer-baseline.json` lists today's violations with their
counts. It only shrinks:
- a rule missing from the baseline, or a count above it, fails;
- a rule fixed or reduced fails until `--update` tightens the baseline;
- `--update` refuses to add or raise anything, and writes a full baseline only
  when none exists;
- a baseline entry above the base revision's baseline fails, so a hand-edited or
  committed increase is caught. The base must exist (exit 2 otherwise), and a
  deleted baseline cannot be rebuilt by `--update` while the base has one.

The first baseline (#1457) records the as-is graph: 35 upward, 206 undeclared
and 30 two-way module pairs from 1,094 file edges. No manifest declares
`dependsOn` yet. Scopers declare real dependencies and the baseline shrinks with
each slice.

## Verify

`scripts/tron test tooling scripts/test-tron-layers.py` builds fixture
TypeScript projects with the real `tsconfig.json` and installed compiler. It
covers declared, type-only and dynamic edges; upward, re-export and grown-pair
mutations; baseline shrink-only rules; and error exits. Output is kept in
`test-results/layers-cli/`.
