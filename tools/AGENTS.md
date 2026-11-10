# Repository tooling guide

Read this before editing `scripts/` or `tools/`, with the [root charter](../AGENTS.md), which binds
everywhere. `scripts/tron --help` lists every command; each `tools/<tool>/` keeps its own README except `tools/budgets`, folded below.

## Doc budgets (`tools/budgets`)

`scripts/tron budgets` reports doc sizes against their budgets for one commit
and fails only on a doc far over its budget. Code size is not budgeted:
splitting an owner is justified by locality and ownership, not its line count
(`scripts/tron metrics` reports sizes as trailing evidence).

```bash
scripts/tron budgets            # HEAD
scripts/tron budgets <rev>
```

Exit 0: no problem. Exit 1: problems, one per line. Exit 2: usage error or an
unmeasurable revision. None of these is reported as clean. The summary line
always reports the docs over budget.

### Rules

Categories and line counts come from `tools/metrics` (`read_tree`), so the
checker and the metrics report cannot drift. It reads Git objects only: commit first.

**A doc fails above twice its budget**, and reports above its budget:

| Doc (metrics `docs`) | Budget | Fails above |
|---|---|---|
| `packages/<name>/README.md` | 200 | 400 |
| any other `README.md` | 150 | 300 |
| other docs | 300 | 600 |

The root `README.md` (250) fails at its budget itself: the front door stays short.
`AGENTS.md` files are not budgeted; the charter keeps them concise. Manifests carry no size exceptions.

### Verify

`scripts/tron test tooling tools/budgets/tests/test-budgets.py` runs the CLI on
disposable repositories: docs at twice their budget pass and one line more
fails, the root README fails one line over its budget, AGENTS.md files and code of any size are ignored, and an unknown revision exits 2. Output is
kept in `test-results/budgets-cli/`.
