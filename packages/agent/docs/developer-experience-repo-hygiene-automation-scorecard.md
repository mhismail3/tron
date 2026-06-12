# Developer Experience / Repo Hygiene / Automation Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

This scorecard closes the current-lineage Developer Experience / Repo Hygiene /
Automation slice on branch `codex/developer-experience-repo-hygiene-automation-current`.
The branch was created from `485819810382db7f763196b8305426e1f3f8a839`
(`Harden iOS thin-client runtime shell`). The older
`codex/developer-experience-repo-hygiene-automation` branch is stale branch
evidence only; its `9ef779cf5` head remains quarry-only and was not merged,
cherry-picked, or copied wholesale.

The goal is one predictable contributor workflow for setup, dev server use,
local and GitHub tests, generated projects, docs, inventories, branch handoff,
local/remote pickup, and ignored-artifact hygiene.

| Row | Name | Weight | Status | Evidence |
| --- | --- | ---: | --- | --- |
| DXRHA-0 | Baseline, lineage, and stale-branch quarantine | 5 | passed | Verified current branch ancestry from `485819810382db7f763196b8305426e1f3f8a839`, recorded the stale `codex/developer-experience-repo-hygiene-automation` branch at `9ef779cf5` as quarry-only, and captured source-audited workflow surfaces before edits. |
| DXRHA-1 | Whole contributor workflow inventory | 10 | passed | Added the narrative and TSV inventories covering setup, dev server, local CI, GitHub CI, static gates, generated projects, version/release helpers, personal-info guard, docs upkeep, predecessor inventories, branch handoff, ignored artifacts, release boundaries, and test surfaces. |
| DXRHA-2 | scripts/tron UX and command dispatch discipline | 10 | passed | Audited `scripts/tron` dispatch/help, `scripts/tron.d/quality.sh`, README CLI reference, PR template, and contributor docs; no production deploy alias was added, and contributor docs now use the actual `tron dev --stop` flow. |
| DXRHA-3 | Local CI and GitHub CI target parity | 12 | passed | Added `developer_experience_repo_hygiene_automation_invariants` to `scripts/tron.d/quality.sh` and `.github/workflows/ci.yml`; the new invariant parses both target lists and fails if the order or contents drift. |
| DXRHA-4 | Generated artifact discipline | 10 | passed | Reconfirmed iOS `TronMobile.xcodeproj` is tracked and drift-checked, Mac `TronMac.xcodeproj` is generated and ignored, and helper binaries stay ignored under `Contents/Library/LoginItems/.../tron`. |
| DXRHA-5 | Stale tracked ignored/build artifact hygiene | 8 | passed | The invariant executes `git ls-files -ci --exclude-standard` and source-checks ignore coverage for Rust targets, Xcode build outputs, `.xcresult`, DerivedData, script artifacts, Node modules, and helper binaries. |
| DXRHA-6 | Setup/dev server path and runtime-state clarity | 10 | passed | README and script guards now agree that `tron dev -bd --json --wait <seconds>` is the automation path, port `9847` is explicitly owned during dev takeover, and `~/.tron` includes seeded profile, workspace, memory, and internal runtime state. |
| DXRHA-7 | Version and release-helper sanity | 8 | passed | CI, README, and helper scripts keep `VERSION.env`, `scripts/tron version check/test`, and `scripts/tron-release-notes --test` visible without adding deploy automation. |
| DXRHA-8 | Docs/inventory/README upkeep workflow | 8 | passed | README, CONTRIBUTING, PR template, scorecard/evidence artifacts, and predecessor inventories were updated together; the invariant rejects stale closed-artifact wording and missing README references. |
| DXRHA-9 | Branch, handoff, and remote pickup hygiene | 7 | passed | The scorecard, evidence, and inventory record branch naming, stale branch quarantine, `git status --short`, and enough local/remote pickup context that another thread can continue without chat history. |
| DXRHA-10 | Broad verification and final closeout | 12 | passed | The DXRHA invariant, local/GitHub CI wiring, README/predecessor inventory updates, personal-info guard, version helpers, release-notes helper, XcodeGen drift check, whitespace check, ignored-file scan, and clean status are recorded in the evidence manifest. |

## Closed Findings

- The local `closeout_test_targets` array and GitHub `rust-static-gates` command
  block were manually mirrored. DXRHA keeps that mirror but adds a parser-based
  invariant so future target-set drift fails locally.
- `CONTRIBUTING.md` still described the Mac helper as
  `Contents/Resources/tron-agent`. The current Mac docs, project resources, and
  CI validate helpers under `Contents/Library/LoginItems/Tron Server*.app/Contents/MacOS/tron`.
- The README install-directory note said startup no longer creates top-level
  memory state, while `scripts/tron-lib.sh` seeds `~/.tron/memory/{rules,sessions}`.
  The README now matches the script.

## Handoff

Use branch `codex/developer-experience-repo-hygiene-automation-current`.
The stale branch `codex/developer-experience-repo-hygiene-automation` remains
quarry-only. Final pickup should verify `git status --short`, rerun the DXRHA
target if touching workflow docs, and preserve the local/GitHub closeout target
parity guard.
