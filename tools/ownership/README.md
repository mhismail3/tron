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
scripts/tron ownership --card <id|path>  # one module's card, dependents and dependencies (below)
scripts/tron tidy [--json|--prune] # workspace hygiene (below)
scripts/tron tidy --here [--landing]     # this worktree's residue; exit 1 until it is clean
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
  | `dependsOn` | no | other module ids |
  | `dynamicEdges` | no | `{to, kind, via?, why}`: `to` is another module id; `kind` is `registration`, `spawn`, `fs-read`, `generated` or `wire`; `via` is a tracked repo-relative path; `why` is non-empty |
  | `capabilities` | no | non-empty strings (the catalog does not exist yet) |
  | `verify` | no | `scripts/tron …` commands |
  | `riskClass` | no | `kernel`, `contracts`, `persistence`, `security`, `lifecycle`, `ios-ui`, `mac-installer` |
  | `interfaces` | card | inbound contracts; see [Purpose cards](#purpose-cards) |
  | `uses` | no | outside contracts the module depends on: `{name, kind, why?}`; `name` must occur in an owned file |

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
common parent. A repo tool keeps its code, `tests/` and configuration in
`tools/<tool>/` beside its one manifest (for example `tools/work/work.module.json`).
Edges, capabilities, risk classes and verification declarations are optional
fields checked by their owning tools. `--modules` prints the current map.

## Purpose cards

A card answers, for one module: what is it for, who reaches it, what does it reach, and
which checks go red if it breaks. It is the manifest's `purpose`, `interfaces` and `uses`
keys plus its guardians: the tests it owns and its `verify` commands. Before editing a
module, read `scripts/tron ownership --card <module-id or any path it owns>`: it prints the
card, the modules whose files name this one (`foundDependents`, with file names) and the
modules it names (`foundDependencies`), whether or not a card declares them yet.

```json
{"layer": "L5", "owns": ["**"], "purpose": "Runs the iOS UI tests on leased simulators.",
 "interfaces": [{"name": "scripts/tron-ios-test", "kind": "exec", "consumers": ["repo/verify"],
                 "external": "maintainer and agents in Terminal"}],
 "uses": [{"name": "DEVELOPER_DIR", "kind": "env"}]}
```

- **`interfaces`** entries are `{name, kind, consumers?, external?}`. `name` is an owned
  file or single-owner directory, or a contract name (subcommand, RPC, env var) that occurs
  in an owned file. `kind` is `exec`, `import`, `read`, `cli`, `env`, `wire`, `fs` or
  `launchd` (`exec`, `import` and `read` name a tracked path; `wire` covers protocols, events and data formats). `consumers` are module ids; `external` says who outside the repository uses it.
  Each entry needs one of the two.
- **References are found, not trusted.** Each tracked source file (not Markdown, not a
  manifest) is scanned for names of tracked files and single-owner directories, resolved
  from the root, the file's package and its own directory; a distinctive bare file name
  counts in its own directory, and so does a Python `import` of a sibling. A comment that
  names a path counts: a move must update it too.
- **Checks** for every module not exempt (each message names the fix): a purpose; a
  guardian; at least one interface; every module whose files name an owned file is a
  listed consumer of an interface covering it, and every listed consumer still names it;
  an interface path the module no longer owns is refused with the files that still name
  it (a half-done move); and every owned non-test file is reached by another owned
  non-test file or covered by an interface (otherwise it is dead: delete it).
- **Ratchet.** `layout.uncarded` in `root.module.json` lists the modules still exempt. It
  only shrinks against origin/main, an entry whose card is complete is stale, and a new
  module is carded from birth.

Outbound edges are derived, never declared twice: a module's dependencies are the
interfaces of other modules that list it, plus `dependsOn` and `dynamicEdges`.
`scripts/tron probe` (tools/verify/README.md) checks that the guardians actually go red.

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
- **`uncarded`**: modules not yet [carded](#purpose-cards); see the ratchet there.
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
(including empty ignored directories, which Git does not list, and the parts of an
ignored directory such as `packages/ios-app/build/` that its writer does not own);
tracked files the ignore rules also match; `__pycache__`; `.scratch/` entries and
loose `.pi/` files (the workflow scripts Pi's subagent tool asks for) older than 7
days and `test-results/` entries older than 14 days, aged by the newest file inside; tooling no tracked code, config or test names
(report-only, by file name); directories in `<checkout>-worktrees/` that are not
registered worktrees; a pre-commit hook that differs from what
`scripts/install-hooks.sh` writes; each worktree's merged/dirty/live state and last
HEAD activity; and branches merged into `origin/main` or idle over 14 days. Exit 1
means something needs a decision; `--json` prints the same report.

`--here` checks only the current worktree, the residue its agent owns: untracked files,
ignored paths with no named writer, any `.scratch/` or loose `.pi/` entry, and worktrees
pi-subagents left under `<checkout>-worktrees/worktrees/<this worktree>/`. It exits 1 until
they are gone; an agent runs it before it reports or parks. `--here --landing` checks only
untracked files and unnamed ignored residue, and is a `scripts/tron verify` step, so residue
cannot land.

`--prune` deletes only expired scratch and evidence (never through a symlinked
`.scratch` or `test-results`, and never in a linked worktree with a live process,
local changes or unknown ignored data, or in any linked worktree without `lsof`:
that is another worker's), bytecode, branches merged into `origin/main` (not
merely into a local main) that no worktree has checked out (printing `git branch <name> <sha>`
to restore each), and merged worktrees on a branch (a detached worktree belongs to the tool that
made it, such as a verify batch lane) with no untracked, modified or
non-regenerable ignored file (an ignored `.env.local` keeps it), no process whose
working directory is inside, and no HEAD activity for 3 days. Without `lsof` it
prunes no worktree. Unmerged branches, residue and orphan directories are only
reported. Other stores keep their owners: `scripts/tron-ios-test prune` owns
`~/Library/Developer/Tron/ios`.

## Verify

`scripts/tron test tooling tools/ownership/tests/test-ownership.py tools/ownership/tests/test-layout.py
tools/ownership/tests/test-cards.py tools/ownership/tests/test-tidy.py tools/ownership/tests/test-tidy-scope.py`
runs the CLIs against disposable Git repositories: ownership (valid layouts, coverage and
schema violations, placement, Git-only discovery), one case per layout rule and the
shrink-only lists, one per card rule (undeclared and stale consumers, a half-done move,
dead files, the exemption ratchet, `--card`), and tidy's report, `--here`, prune safety and
ownership scope. The last runs are kept under `test-results/{ownership,layout,cards,tidy}-cli/`.
