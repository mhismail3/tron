# Budgets

`scripts/tron budgets` checks file-size and doc budgets for one commit
([plan §6.7 V6](../../docs/restructure/plan.md#67-structure-checkers-v5-v6-v8-v9-v10), [§3 M2](../../docs/restructure/plan.md#m2-locality-and-conflict-surface-primary-objective)).
It reports and is never wired into a hook, landing or queue.

```bash
scripts/tron budgets                     # HEAD, bounded by origin/main
scripts/tron budgets <rev> --base <ref>
```

Exit 0: every file is within budget or excepted. Exit 1: problems, one per line.
Exit 2: usage error, an unmeasurable base, or ownership violations at the
revision. None of these is reported as clean.

## Budgets

Categories and line counts come from `tools/metrics` (`read_tree`), so the
checker and `M2.fileSize` cannot drift. The checker reads Git objects only:
commit first.

| Files (metrics category) | Budget |
|---|---|
| production, tests, tooling | 500 lines (`lines`); 501 is over, as in `M2.fileSize` |
| `packages/<name>/README.md` (docs) | 200 lines (`doc`, package index, §5.6) |
| any other `README.md` (docs) | 150 lines (`doc`, module README) |
| other docs | 300 lines (`doc`, cross-module contract) |

The root `README.md` (250) and `AGENTS.md` (150) keep their budgets in
`scripts/check-documentation-policy.py`, which the charter names; they are not
double-checked here.

## Exceptions

An over-budget file passes only with an exception in its owning manifest's
`exceptions` field: `{path, budget, reason, exit}` (validated by
`tools/ownership`; `budget` is `lines` or `doc`). Exceptions are shrink-only
against the base revision (default `origin/main`; it must be measurable):
- an over-budget file with no exception fails;
- an exception the base lacks fails. A Git move (`diff -B -M`) keeps its
  exception, bounded by the base path. A new file at a path whose old file
  moved away inherits nothing, and a copy inherits nothing;
- an excepted file larger than at the base fails;
- an exception whose file is within budget, or deleted, is stale and fails
  until removed.

Only the change that introduces this checker seeds exceptions: the base has no
`tools/budgets/budgets.py`, and neither does `origin/main` (so once it lands,
no `--base` can reopen seeding). As with every repository tool, the rules
themselves are the checked-out code; a change to them is reviewed like any
other change. That was #1460: 226 exceptions
in 51 manifests, covering 202 code files over 500 lines and 24 docs over their
budget. `docs/restructure/plan.md` is exempt from budgets entirely under plan §0
until M6 (its steward records decisions in it), so it carries no exception.

## Verify

`scripts/tron test tooling scripts/test-tron-budgets.py` runs the CLI on
disposable repositories. It covers seeding; growth, new-file and
new-exception known-bads; the 500/501 edge; shrink, stale, removal and rename;
doc budgets; and error exits. Output is kept in `test-results/budgets-cli/`.
