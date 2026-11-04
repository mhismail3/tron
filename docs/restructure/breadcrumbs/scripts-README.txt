# Repository tooling

Everything people or agents run against this checkout starts at `scripts/tron`. Each job
has one command and one owning area; look here (and `scripts/tron ownership --ledger`)
before writing a new script: extend the owner instead of adding a parallel one.

## Commands

| Command | Area | Job |
|---|---|---|
| `scripts/tron dev …` | `dev/` | Debug Gateway lifecycle (port 9848) |
| `scripts/tron-fsevents-guard …` | top level (frozen) | fseventsd monitor (LaunchAgent embeds its source) |
| `scripts/tron test gateway\|ios\|tooling …` | `verify/`, `ios/` | run one suite directly |
| `scripts/tron verify …`, `mutate`, `health` | `verify/` | affected checks, post-land batch, mutation, scorecard |
| `scripts/tron ownership [--layout\|--ledger\|--modules]` | `structure/` | owners, layout rules, per-file ledger |
| `scripts/tron layers`, `metrics` | `structure/` | layer ratchet, line metrics |
| `scripts/tron tidy [--prune\|--json]` | `structure/` | residue, scratch, worktree and branch hygiene |
| `scripts/tron docs`, `hook pre-commit` | `policy/` | generated docs, privacy/doc/agent policy, hooks |
| `scripts/tron work …` | `work/` | privacy-checked GitHub issue writes |
| `scripts/tron ios generate\|source\|simulator\|release-doctor` | `toolchain/`, `ios/` | XcodeGen, main source, simulator, release preflight |
| `scripts/tron mac generate\|verify\|reinstall\|replace`, `checkpoint` | `toolchain/`, `mac/` | Mac app build, verification, replacement |
| `scripts/tron profile …`, `triage …` | `profile/`, `triage/` | performance capture, incident triage |
| `scripts/tron version`, `bundle gateway`, `build`, `chat`, `diagnose` | `toolchain/`, packages | version, payload, Gateway build/chat/diagnose |
| `scripts/tron-node exec …` | top level | pinned development Node |

`scripts/tron-ios-device`, `scripts/tron_mac_replace.py` and `scripts/tron-fsevents-guard` stay
at this exact path: the installed Gateway or the replace orchestrator runs them from this
checkout (the guard at older revisions). Change their content, never their path.

## Layout rules

- Top level: only `tron`, `tron-node`, the three frozen paths, this README and
  `scripts.module.json`.
- `scripts/<area>/` holds the area's commands, libraries, tests and `<area>.module.json`.
  Tests are `test-<subject>.py|sh` or `<subject>.test.mjs` beside the file they prove and run
  against temporary Git repos and `HOME`.
- Package-specific tooling lives in `packages/<pkg>/scripts/`, not here.
- Every script's first comment line says what it does and who runs it.

## Add, change, remove

1. Search the table above and `scripts/tron ownership --ledger | grep <word>`.
2. Put the file in the owning area (or a new area with its own manifest and a row here),
   add a `scripts/tron` arm if people run it, and add its test beside it.
3. To remove: delete the file, its tests, its `scripts/tron` arm and its manifest entry in
   one change. `scripts/tron tidy` lists tooling that no code, config or test names.

`scripts/tron ownership --layout` (pre-commit) prints the exact fix for a misplaced file.
