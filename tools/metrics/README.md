# Repository metrics

`scripts/tron metrics` measures one commit. Counts are trailing evidence, not
phase targets or required closing paperwork.
It reports and never gates: the exit status is non-zero only for a usage or Git
error (an unknown revision exits 2 and writes nothing).

```bash
scripts/tron metrics                      # HEAD
scripts/tron metrics <rev>                # any commit, without checking it out
scripts/tron metrics --compare <base>     # delta table <base> → HEAD
scripts/tron metrics --compare <base> <head>
```

Each measured commit is written to `test-results/metrics/<sha>.json` (keys
sorted, no wall-clock time, no machine paths). `--compare` measures both commits
with the current rules, writes both files, and prints a Markdown table plus a
one-line `Metrics Δ:` summary for slice closing comments. Stored JSON is never
read back, so a comparison cannot mix classification rules.

## Determinism

Everything comes from Git objects of the named commit: `git ls-tree -r` for the
inventory, `git cat-file --batch` for contents, and commit history for the
hotspot window. The working tree, index, untracked files and the clock are never
read, so the same commit always produces byte-identical JSON.

## Classification

Every tracked path gets exactly one category, by the first matching rule.
Rules use only the path, the Git file mode and the blob bytes.

1. Gitlink (submodule) → `thirdParty`; symlink → `data`.
2. A NUL byte in the first 8,000 bytes (Git's own heuristic) → `binary`.
3. `package-lock.json`, `*-package-lock.json`, `npm-shrinkwrap.json`,
   `yarn.lock`, `pnpm-lock.yaml`, `Package.resolved` → `lockfile`.
4. Under a `third_party/` directory, or a `LICENSE`/`NOTICE`/`COPYING` file
   (also `*-LICENSE.txt` and similar; no suffix, `.txt` or `.md`) → `thirdParty`.
5. `.md`, `.mdx` → `docs`.
6. Code: suffix `.ts .mts .cts .tsx .js .mjs .cjs .jsx .swift .py .sh .bash .c
   .h .m .mm .css .html`, or no suffix and a `#!` first line. Then:
   - `tests` if the name matches `*.test.<ext>` (including `.integration.test`
     and `.e2e.test`), starts with `test-`/`test_`, is a `vitest*.config.*`, is
     an iOS hosted fixture or probe (`Hosted*Fixture*.swift`,
     `Hosted*Probe*.swift`, `*HostedProbe.swift`), or any directory is
     `test-support`, `test-fixtures`, `tests`, `Tests`, `fixtures`, `Fixtures`,
     `E2ETests`, `ProfilingTests` or ends in `UITests`, or the path is listed in
     `TEST_PATHS` (the never-shipped Mac Terminal journey probe);
   - `production` for shipped sources kept beside tooling (listed in
     `PRODUCTION_PATHS`: the Mac Gateway launcher C source);
   - `tooling` under `scripts/`, `tools/`, `.agents/`, `.github/`,
     `.pi/` or `packages/<name>/scripts/`, any `.py`/`.sh`/`.bash` file, and any
     suffixless executable;
   - otherwise `production`.
7. Other text in a directory whose name contains `fixture` or is
   `test-support`, or named `*.golden.*` → `fixtures`.
8. Everything else (configuration, manifests, assets, data) → `data`.

Paths are Git's bytes decoded as UTF-8; undecodable bytes are kept as escapes.

**Hand-written** = `production + tests + tooling + docs`. `fixtures` (golden and
fixture data) is reported separately so adding locks does not fight the size
target. `data`, `lockfile`, `thirdParty` and `binary` are excluded from
hand-written totals but reported with file, line and byte counts.

Known consequences: SwiftPM `Package.swift` counts as code by its suffix;
hosted fixtures count as tests although they compile into the iOS app target
under `HOSTED_TEST`, as does `ChatHostedProbe.swift`. Tracked generated outputs
today are data files (model release dates, asset catalogs), so there is no
generated-code category. Ownership-based classification arrives with the 0.4 manifests.

**Package** = the second path segment under `packages/`, else the first segment,
else `(root)`.

## Observed metrics

- **Lines** = LF count, plus one for a non-empty final line without LF. Blank and
  comment lines count. Binary files have zero lines and report bytes.
- **`M3.size`**: hand-written lines and files, per-category files/lines/bytes for
  all categories, and hand-written lines per package and category.
- **`M2.fileSize`**: hand-written files with more than 500 lines (501 counts, 500
  does not), per category, and the full list sorted by lines then path.
- **`M2.hotspotShare`**: `T` = the measured commit's committer time. The window
  is non-merge commits reachable from the commit with committer time in
  `(T − 30 days, T]`; ancestors dated after `T` (clock skew) fall outside it.
  Touched paths are each commit's paths against its parent (`--no-renames`, so a
  rename touches both names; a root commit touches all its paths), including
  paths later deleted or of any category. The top 10 paths by number of window
  commits (ties by path) are the hotspots; share = window commits touching at
  least one of them ÷ window commits, rounded to four decimals. `touchedPaths`
  counts distinct touched paths; with ten or fewer the share is 100% by
  construction. A window with no commits (a merge whose ancestors are all older)
  reports `share: null`, printed `n/a`, never 0%.

- **`M4.structure`** (from `scripts/tron ownership` and its [card](../ownership/README.md#purpose-cards)
  reference scanner, on the commit's objects): `modules`; `uncarded`, the modules
  `layout.uncarded` still exempts; `rootEntries`; `scriptsTopFiles`, files directly in
  `scripts/`; `crossModuleReferences`, distinct (consumer module, named file or directory)
  pairs; `modulePairs`, module pairs with at least one; and `unreachedFiles` with the list
  `unreached`: owned non-test source files no tracked file names. Swift files are left out
  (they resolve by type, which `scripts/tron layers ios` measures). An additive key: the
  schema stays `tron-metrics/1`, whose `M3.size` `scripts/tron health` reads.

## Not measured here

Verify records per-run step timings in `test-results/verify/<sha>.json`.
Metrics does not read those reports: execution duration is not derivable from Git objects.

Import edges are not inferred from text search (`scripts/tron layers` owns the graph): type-only, dynamic,
re-exported and path-mapped imports make a grep graph wrong in both directions.

## Compare

Totals come from the two snapshots, so renames never double count. The change
table pairs paths with `git diff -M` (Git's default 50% similarity, rename limit
raised to 100,000) and attributes the hand-written line delta to `added`,
`deleted` (its base lines subtracted), `renamed` and `modified`; the rows sum to
the hand-written total delta. A pair whose category changed is listed as
`reclassified` (its delta stays in its change row; a file moved into or out of a
hand-written category contributes its full lines). Files over 500 lines are
followed through renames and listed as `renamed`, `left` (deleted, or now at or
under the threshold) or `entered`.

## Verify

`scripts/tron test tooling tools/metrics/tests/test-metrics.py` runs the CLI against
disposable Git repositories and keeps the last fixture comparison under
`test-results/metrics-cli/`.
