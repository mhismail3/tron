# Module ownership

Every tracked path has exactly one owning module. A module is declared by a
co-located `<name>.module.json` manifest (format B′, [plan §6.1](../../docs/restructure/plan.md#61-module-manifest-v1)).
`scripts/tron ownership` checks the whole repository. It is read-only and
reports; it is never wired into hooks, landing or a queue.

```bash
scripts/tron ownership             # index paths, working-tree manifest contents
scripts/tron ownership <rev>       # one commit's Git objects, without checking it out
scripts/tron ownership --modules   # also print id, layer, owned paths, manifest
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
  | `layer` | yes | `L0`–`L5` ([plan §5.1](../../docs/restructure/plan.md#51-layers-all-packages)). Code modules use their current best-fit layer; tooling, docs, test targets and package configuration use `L5`, because nothing depends on them |
  | `owns` | yes | non-empty list of unique patterns, relative to the manifest's directory |
  | `dependsOn` | no | other module ids; kernel ports (plan §6.1) are accepted once K-0 defines them |
  | `dynamicEdges` | no | `{to, kind, via?, why}`: `to` is another module id; `kind` is `registration`, `spawn`, `fs-read`, `generated` or `wire`; `via` is a tracked repo-relative path; `why` is non-empty |
  | `capabilities` | no | non-empty strings (the catalog does not exist yet) |
  | `verify` | no | `scripts/tron …` commands |
  | `riskClass` | no | `kernel`, `contracts`, `persistence`, `security`, `lifecycle`, `ios-ui`, `mac-installer` |
  | `exceptions` | no | `{path, budget, reason, exit}`: `path` is a file this module owns (relative), `budget` is `lines` or `doc`, and `reason` and `exit` are non-empty |

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
Only `layer` and `owns` are filled in for now. Edges, capabilities and risk
classes arrive with the tools that can check them (plan §7, 0.5–0.11).
`--modules` prints the current map.

## Verify

`scripts/tron test tooling scripts/test-tron-ownership.py` runs the CLI against
disposable Git repositories: valid layouts, coverage and schema violations,
placement and Git-only discovery. The last run is kept under
`test-results/ownership-cli/`.
