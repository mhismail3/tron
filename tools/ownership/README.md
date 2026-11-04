# Module ownership

Every tracked path has exactly one owning module. A module is declared by a
co-located `<name>.module.json` manifest (format B′).
`scripts/tron ownership` checks the whole repository and the [layout](#layout)
`root.module.json` declares. It is read-only; `scripts/tron verify` runs it as its
first static step.

```bash
scripts/tron ownership             # index paths, working-tree manifest contents
scripts/tron ownership <rev>       # one commit's Git objects, without checking it out
scripts/tron ownership --modules   # also print id, layer, owned paths, manifest
scripts/tron ownership --ledger    # path, module, layer and purpose of every tracked path
scripts/tron tidy [--json|--prune] # workspace hygiene (below)
```

Exit 0: every path is owned exactly once and every manifest is valid. Exit 1:
one sorted line per violation, then a summary. Exit 2: usage or Git error.

## Discovery

Paths come from Git only: `git ls-files` (so a new file counts once it is
`git add`ed) or `git ls-tree -r <rev>`. Nothing walks the filesystem, so
untracked build output, DerivedData and `node_modules` never count. Manifests
are the tracked paths ending in `.module.json`. There is no central registry.

## Manifest

```json
{"layer": "L3", "owns": ["**"]}
```

- **Name and id.** The file is `<name>.module.json`, with `<name>` in lowercase
  kebab case. The id is `<package>/<name>`: `<package>` is the directory under
  `packages/`, otherwise `repo`. Ids are unique.
- **Placement.** The manifest goes in the lowest common directory of the
  files it owns. A directory may hold several, so a mixed directory such as
  Gateway `src/sessions/` is split by explicit file lists. Two locations are
  refused:
  - inside a directory an XcodeGen spec copies whole (a block-form
    `- path:` source with `type: folder` in a tracked `packages/*/project.yml`);
  - below a SwiftPM package root (a directory with `Package.swift`). Place
    the manifest beside `Package.swift` instead.

  The iOS and Mac directory sources exclude `**/*.module.json` and
  `**/README.md` (#1363), so other placements never reach a bundle.
- **Keys.** Unknown keys and duplicate keys are errors.

  | Key | Required | Rule |
  |---|---|---|
  | `layer` | yes | `L0`–`L5` ([layers](../layers/README.md#layers)). Code modules use their current best-fit layer; tooling, docs, test targets and package configuration use `L5`, because nothing depends on them |
  | `owns` | yes | non-empty list of unique patterns, relative to the manifest's directory |
  | `purpose` | no | one line; `--ledger` shows it for owned files that state none themselves |
  | `layout` | no | only in `root.module.json`; see [Layout](#layout) |
  | `dependsOn` | no | other module ids; kernel ports (plan §6.1) are accepted once K-0 defines them |
  | `dynamicEdges` | no | `{to, kind, via?, why}`: `to` is another module id; `kind` is `registration`, `spawn`, `fs-read`, `generated` or `wire`; `via` is a tracked repo-relative path; `why` is non-empty |
  | `capabilities` | no | non-empty strings (the catalog does not exist yet) |
  | `verify` | no | `scripts/tron …` commands |
  | `riskClass` | no | `kernel`, `contracts`, `persistence`, `security`, `lifecycle`, `ios-ui`, `mac-installer` |

  Lists must not repeat an entry.

## Patterns and ownership

A pattern is matched segment by segment against a tracked path below the
manifest's directory:
- `*` and `?` match within one segment, including a leading dot;
- `**` must be a whole segment and matches zero or more segments;
- a pattern without wildcards names one file.

Leading or trailing `/`, empty, `.` or `..` segments, and `[ ] { } \` are
refused. There is no negation and no precedence.

**Exactly one:** across all manifests, each tracked path matches exactly one
`owns` entry. A second match, even inside the same manifest, is a double claim;
narrow the glob or list the files. Manifests are tracked paths like any other,
and each must be owned by itself. An entry that matches no tracked path is
stale and reported, so manifests move with their code.

## As-is modules

The current manifests describe today's owners, not the target tree. The
default owner is one manifest per directory with `"owns": ["**"]`. Mixed
directories are split by explicit lists, and cross-directory owners sit at the
common parent (for example `work.module.json` at the root owns
`tools/work/**`, its `scripts/test-work-*.py` tests and `.github/work.json`).
Edges, capabilities, risk classes and verification declarations are optional
fields checked by their owning tools. `--modules` prints the current map.

## Layout

`root.module.json` `layout` declares where files may go; `tools/ownership/layout.py`
checks it in the same pass, and each message names the fix:

- **`root`**: the only top-level entries. A new one is refused.
- **`scriptsTop`**: the only files directly in `scripts/`. New tooling goes in
  `scripts/<area>/` (or beside its tool in `tools/<tool>/` until that moves) with
  its tests and manifest, plus a `scripts/tron` subcommand if people run it.
- **`frozen`**: paths code older than the checkout runs by path (the installed
  Gateway, or the Mac replace orchestrator at another revision). They must exist;
  change their content, never their path.
- **Purpose.** Tooling (`.py`, `.sh`, `.mjs`, `.js`, `.ts` or executable files under
  `scripts/`, `tools/` and `packages/<pkg>/scripts/`, except tests) states what it does in
  a comment or docstring in its first 12 lines. Directives such as `# shellcheck`
  do not count. `--ledger` prints that line.
- **Tests** sit beside the code they prove: none in the root, `docs/`, `config/`,
  `.agents/` or `.github/`; Swift `*Tests.swift` only in `UITests/`, `E2ETests/`,
  `ProfilingTests/`, `SwiftAppUITests/` or `Tests/`.

`root` and `scriptsTop` were seeded from the tree that declared them and only
shrink. An entry with nothing left to allow is stale and must be removed. The CLI
also compares the layout with `root.module.json` at the merge base with
`origin/main`: an entry this change added to either list is refused (put the file
where it belongs instead), and so is removing a frozen path together with its entry.
Without `origin/main` that comparison cannot run and the CLI exits 2. In-process
readers of one revision (verify selection, docs, layers, the batch) check the tree
without the comparison. A repository without `layout` gets ownership checks only.

## Workspace hygiene

`scripts/tron tidy` (`tidy.py`) reports, for the primary checkout and every
registered worktree: untracked files; ignored paths with no named writer
(including empty ignored directories, which Git does not list); `__pycache__`;
`.scratch/` entries older than 7 days and `test-results/` entries older than 14
days, aged by the newest file inside; tooling no tracked code, config or test names
(report-only, by file name); directories in `<checkout>-worktrees/` that are not
registered worktrees; a pre-commit hook that differs from what
`scripts/install-hooks.sh` writes; each worktree's merged/dirty/live state and last
HEAD activity; and branches merged into `origin/main` or idle over 14 days. Exit 1
means something needs a decision; `--json` prints the same report.

`--prune` deletes only expired scratch and evidence (never through a symlinked
`.scratch` or `test-results`), bytecode, branches merged into `origin/main` (not
merely into a local main) that no worktree has checked out (printing `git branch <name> <sha>`
to restore each), and merged worktrees with no untracked, modified or
non-regenerable ignored file (an ignored `.env.local` keeps it), no process whose
working directory is inside, and no HEAD activity for 3 days. Without `lsof` it
prunes no worktree. Unmerged branches, residue and orphan directories are only
reported. Other stores keep their owners: `scripts/tron-ios-test prune` owns
`~/Library/Developer/Tron/ios`.

## Verify

`scripts/tron test tooling scripts/test-tron-ownership.py tools/ownership/tests/test-layout.py
tools/ownership/tests/test-tidy.py` runs the CLIs against disposable Git repositories:
ownership (valid layouts, coverage and schema violations, placement, Git-only
discovery), one case per layout rule and the shrink-only lists, and tidy's report
and prune safety. The last runs are kept under `test-results/{ownership,layout,tidy}-cli/`.
