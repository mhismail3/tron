# Repository structure plan (#2276)

Goal: agents find and own code fast, with fewer collisions and regressions. One home per kind of
file, one entry point per job (`scripts/tron`), every tracked file owned, scratch and residue
pruned, and guards whose failure message names the fix. The maintainer approved the plan on
2026-11-04; on 2026-11-05 every remaining item was re-asked with Musk's design order (question
the requirement, delete, simplify, accelerate, automate last). The Phase-A audit (per-path
ledger, scout tables, prototypes) is in this merge's second parent, `b9ee64938`; the ledger is
generated now (`scripts/tron ownership --ledger`), so it is not kept on main.

## Status

| Slice | State | Musk verdict |
|---|---|---|
| S1 guards: layout rules in `scripts/tron ownership`, `--ledger`, `tidy`, AGENTS "Where things go" | landed `4121a32c2` | keep: 0.2 s, blocks new root entries, root manifests and flat scripts at commit |
| S2 residue, ignore rules, first `tidy --prune` | landed `5e4bbacd1` | keep; `tidy --prune` root-fixed for read-only payloads in `3de01846d` |
| S3 fold `tools/` into `scripts/<area>/` | **changed** to S3', landed with this change | see below |
| S4a/b/c flat `scripts/` into areas | **dropped** | see below |
| S5 packages and docs | **narrowed**; done except `tools/web` | deletions kept; moves re-judged below |
| S6 weekly hygiene automation | maintainer decision | recommend `tidy --prune`, not report-only |

## Re-judged items

**S3' instead of S3.** Why fold `tools/` into `scripts/`? So one job has one home. Why does that
matter to an agent? A tool's tests sit elsewhere (`tools/verify` vs `scripts/test-tron-verify*.py`)
and seven root manifests each own one tool plus its stray tests. Why are they split? Tests were
put beside the dispatcher, not the tool. The harm is the split, not the directory name: moving
whole tools across homes rewrites ~96 referencing files and verify's own selector for no further
gain, since `scripts/tron` is already the one front door. S3': each tool keeps its directory and
gains its tests (`tools/<tool>/tests/`, as `tools/ownership` already does) and its manifest; the
root keeps only `root.module.json`. `tools/work/work.json`, its configuration, moved out of `.github`
with its tool.

**S4 dropped.** Why move 108 flat scripts into areas? To find them. Agents find tooling through
`scripts/tron --help`, `--ledger` purpose lines and grep; the shrink-only layout guard already
stops growth. The moves touch frozen executed paths, Xcode build phases and the payload
fingerprint inputs: the highest regression risk in the plan for no measured gain. Kept from S4:
`tidy`'s dead-tooling report, acted on as deletions.

**S5.** Kept and done: delete `.codex/` (and the device helper's legacy pair only it used), the
unreferenced pi-subagents `tron.3`-`8` archives, `tools/research` (the global x-posts skill owns
it, D8) and the dated `tools/home-retro/FINDINGS.md`; the kernel design now sits beside its
owner as `packages/gateway/docs/kernel.md`, and Home's improvement-loop design (the rest of
`tools/home-retro/`) as `packages/gateway/src/modules/home/improvement-loop.md`.
Dropped: `VERSION.env` to `config/` (one root entry; touches Xcode config and versioning for no
agent gain); the Mac payload-test and iOS source-policy merges (fold into #2275 when that check
is wired into verify). Deferred until the iOS UI-lock work settles: `tools/web` to
`packages/web` (iOS `project.yml` folder sources and a simulator build).

**S6.** Why a weekly job? Residue piles up when nobody runs the remover (CLEANUP-5WHYS,
`docs/restructure/cleanup-5whys.md`). `tidy --prune` now deletes only what origin/main already has
or what is expired, reports every failure, and restores branches from the printed command, so the
weekly run can prune, not merely report. A Home task cannot create schedules; the maintainer
creates it.

## Rules that stay (enforced by S1)

- Source by module in `packages/<pkg>/`; one manifest per module directory.
- Tests beside what they prove; fixtures in module `fixtures/` or package `test-fixtures/`.
- Repo tooling has a purpose line and a `scripts/tron` subcommand when people run it.
- Agent scratch only in `.scratch/` (7 days); evidence in `test-results/` (14 days).
- No symlinks, aliases or compatibility copies: a move updates its consumers atomically.
- Frozen paths (executed by repo path from older code): `scripts/tron`, `scripts/tron_mac_replace.py`,
  `scripts/tron-ios-device`, `scripts/tron-fsevents-guard`. Their content may change; their path may not.
