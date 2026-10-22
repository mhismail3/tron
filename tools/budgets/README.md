# Budgets

`scripts/tron budgets` reports file sizes and doc budgets for one commit, and
fails only on the two size rules that are hard
([plan §6.7 V6](../../docs/restructure/plan.md#67-structure-checkers-v5-v6-v8-v9-v10), [§3 M2](../../docs/restructure/plan.md#m2-locality-and-conflict-surface-primary-objective)).
Size is reported, never a target: splitting an owner is justified by locality
and ownership, not its line count.

```bash
scripts/tron budgets                     # HEAD against origin/main
scripts/tron budgets <rev> --base <ref>
```

Exit 0: no problem. Exit 1: problems, one per line. Exit 2: usage error or an
unmeasurable revision or base. None of these is reported as clean. The summary
line always reports the code files over 500 lines and docs over budget.

## Rules

Categories and line counts come from `tools/metrics` (`read_tree`), so the
checker and `M2.fileSize` cannot drift. It reads Git objects only: commit first.

- **New production file over 800 lines fails.** "New" means the path is not in
  the base and is not a Git move of a base file (`diff -B -M`, so a rewrite
  that moves a file's content away pairs with its new name). A file at a path
  whose old file moved away is new. Existing files, tests and tooling only
  report against 500 lines, however much they grow.
- **A doc fails above twice its budget**, and reports above its budget:

  | Doc (metrics `docs`) | Budget | Fails above |
  |---|---|---|
  | `packages/<name>/README.md` | 200 | 400 |
  | any other `README.md` | 150 | 300 |
  | other docs | 300 | 600 |

The root `README.md` (250) and `AGENTS.md` (150) keep their hard budgets in
`scripts/check-documentation-policy.py`, which the charter names.
`docs/restructure/plan.md` is exempt until M6 (plan §0). Manifests carry no
size exceptions.

## Verify

`scripts/tron test tooling scripts/test-tron-budgets.py` runs the CLI on
disposable repositories: a new 801-line production file fails and 800 passes;
new tests and tooling only report; an over-500 file growing and an over-800 file
moved pass, and a new file at its old path fails; docs at twice their budget
pass and one line more fails; an unknown base exits 2. Output is kept in
`test-results/budgets-cli/`.
