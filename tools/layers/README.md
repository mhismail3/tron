# Layers

`scripts/tron layers` checks a package's module dependency graph against each
module's manifest `layer` and `dependsOn` ([plan §6.7 V5](../../docs/restructure/plan.md#67-structure-checkers-v5-v6-v8-v9-v10)).
It covers the Gateway and iOS. Mac has no checker until its builds carry a
build stamp. It reports and is never wired into a hook, landing or queue.

```bash
scripts/tron layers [gateway]       # compare with packages/gateway/layer-baseline.json
scripts/tron layers ios             # compare with packages/ios-app/layer-baseline.json
scripts/tron layers ios --update    # remove fixed entries (or write the first baseline)
scripts/tron layers --base <ref>    # bound the baseline by <ref>'s (default origin/main)
```

Exit 0: no violation beyond the baseline. Exit 1: problems, listed one per line.
Exit 2: usage error, ownership violations, an unowned graph file (`git add` and
own it), a missing compiler or Xcode library, or stale iOS evidence. None of
these is ever reported as clean.

## Gateway graph

Edges come from the pinned TypeScript compiler, not a text scan:
`tsc -p packages/gateway/tsconfig.json --noEmit --explainFiles`, run with
`scripts/tron-node`. Every reason a file is in the production program counts:
static, type-only, side-effect, re-export and dynamic imports. Type errors do not
stop the graph. Only edges between two `src/` files are read; tests and
test support are outside the production program and outside this check.
Gateway dependencies must be installed (`npm ci` in `packages/gateway`).

Module owners, layers and `dependsOn` come from `tools/ownership`; nothing here
re-derives ownership.

## iOS graph

Edges come from the Xcode index store that `scripts/tron-ios-test build` writes
into this worktree's products directory, read through the pinned Xcode's
`libIndexStore.dylib` with Python's `ctypes` (no other dependency). File A → B
means A references a symbol, by USR, whose definition is in B. That covers
types, members, extension members and implicit member expressions as the
compiler resolved them.

- **Freshness fence.** The products' `build-identity.json` (owned by
  `scripts/ios-test-build-identity.py`) must equal this worktree's current
  identity (revision, source fingerprint, worktree) on a clean tree. A stale
  stamp, a dirty tree, or a missing stamp or store is refused with "run
  `scripts/tron-ios-test build`". There is no fallback to a text scan. Every
  commit changes the revision, so check after a build of the commit you
  evaluate. A build with no Swift change was incremental and took about 20 s
  (#1459).
- **Units left by earlier builds** for files no longer tracked are ignored.
- **Coverage gaps are ratcheted, not hidden.** Owned `.swift` files the
  stamped build does not index count as `unindexed <module>` entries in the
  same shrink-only baseline. Today that is 18 files: `ProfilingTests` (12) and
  `E2ETests` (2), whose targets the UI Validation build does not compile, and
  the `MacTerminalSSH` package (4, including `Package.swift`), which is
  compiled as a module without index records. Their references are **not**
  checked.

## Rules

For each pair of distinct modules A → B with at least one file edge:
- **upward**: B's layer number is higher than A's;
- **undeclared**: B is not in A's `dependsOn`. Declaring a dependency never
  legalizes an upward edge;
- **two-way**: B also imports A (recorded once per pair).

A rule's count is its number of file edges (a two-way pair counts once); an
`unindexed` rule counts files.

## Baseline

`packages/<package>/layer-baseline.json` lists today's violations with their
counts. It only shrinks:
- a rule missing from the baseline, or a count above it, fails;
- a rule fixed or reduced fails until `--update` tightens the baseline;
- `--update` refuses to add or raise anything, and writes a full baseline only
  when none exists;
- a baseline entry above the base revision's baseline fails, so a hand-edited or
  committed increase is caught. The base must exist (exit 2 otherwise), and a
  deleted baseline cannot be rebuilt by `--update` while the base has one.

The first baselines record the as-is graphs. No manifest declares `dependsOn`
yet; scopers declare real dependencies and the baselines shrink with each slice.
- Gateway (#1457): 35 upward, 206 undeclared and 30 two-way module pairs from
  1,094 file edges.
- iOS (#1459, #1483): 7 upward, 69 undeclared and 13 two-way module pairs from
  2,870 file edges, plus the 18 unindexed files.

## Verify

`scripts/tron test tooling scripts/test-tron-layers.py` builds fixture
TypeScript projects with the real `tsconfig.json` and installed compiler, and
fixture Swift packages indexed by `swiftc -index-store-path` and stamped by the
real identity script. It covers:
- declared, type-only and dynamic TypeScript edges;
- upward, re-export, two-way and grown-pair mutations in both languages;
- units of renamed files, and growth of unindexed files;
- stale, dirty and missing-store refusals;
- baseline shrink-only rules and error exits. Output is kept in
`test-results/layers-cli/`.
